import Foundation

enum MAMEError: LocalizedError {
    case binaryNotFound(String)
    case launchFailed(String)
    case nonZeroExit(Int32, String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(let path):
            return "MAME binary not found or not executable at:\n\(path)"
        case .launchFailed(let message):
            return "Couldn't launch MAME: \(message)"
        case .nonZeroExit(let code, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "MAME exited with code \(code)." + (detail.isEmpty ? "" : "\n\(detail)")
        }
    }
}

/// Thin wrapper around the `mame` command-line binary.
struct MAMERunner {
    let binaryPath: String
    let romPath: String

    private var binaryURL: URL { URL(fileURLWithPath: binaryPath) }

    private func validateBinary() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            throw MAMEError.binaryNotFound(binaryPath)
        }
    }

    // MARK: - Metadata (cheap two-column tools)

    /// `mame -listfull` → shortname → description for every known machine.
    func listFull() async throws -> [String: String] {
        try validateBinary()
        let (stdout, stderr, status) = try await runCapturing(arguments: ["-listfull"])
        guard status == 0 else { throw MAMEError.nonZeroExit(status, stderr) }
        return Self.parseListFull(stdout)
    }

    /// `mame -listclones` → clone → parent for every clone machine.
    func listClones() async throws -> [String: String] {
        try validateBinary()
        let (stdout, stderr, status) = try await runCapturing(arguments: ["-listclones"])
        guard status == 0 || !stdout.isEmpty else { throw MAMEError.nonZeroExit(status, stderr) }
        return Self.parseListClones(stdout)
    }

    // MARK: - Year metadata (from -listxml, but scoped to specific machines)

    /// Runs `mame -listxml <name> <name> …` for a *bounded* batch of machine
    /// names and SAX-parses only the `<year>` of each. The caller is expected to
    /// chunk large sets and cache results — year is static per machine.
    func years(for names: [String]) async throws -> [String: Int] {
        guard !names.isEmpty else { return [:] }
        try validateBinary()
        let (out, err, status) = try await runCapturingRaw(arguments: ["-listxml"] + names)
        guard status == 0 || !out.isEmpty else {
            throw MAMEError.nonZeroExit(status, String(decoding: err, as: UTF8.self))
        }
        let parser = MachineYearParser()
        parser.parse(out)
        return parser.years
    }

    // MARK: - Parsers

    /// Parses `mame -listfull`:
    ///
    ///     Name:             Description
    ///     mslug             "Metal Slug - Super Vehicle-001"
    static func parseListFull(_ output: String) -> [String: String] {
        var map: [String: String] = [:]
        output.enumerateLines { line, _ in
            if line.isEmpty || line.hasPrefix("Name:") { return }
            guard let sep = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return }
            let shortName = String(line[..<sep])
            var description = String(line[sep...]).trimmingCharacters(in: .whitespaces)
            if description.count >= 2, description.hasPrefix("\""), description.hasSuffix("\"") {
                description = String(description.dropFirst().dropLast())
            }
            if !shortName.isEmpty { map[shortName] = description }
        }
        return map
    }

    /// Parses `mame -listclones`:
    ///
    ///     Name:            Clone of:
    ///     mslugx           mslug
    static func parseListClones(_ output: String) -> [String: String] {
        var map: [String: String] = [:]   // clone -> parent
        output.enumerateLines { line, _ in
            if line.isEmpty || line.hasPrefix("Name:") { return }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2 else { return }
            map[String(parts[0])] = String(parts[1])
        }
        return map
    }

    // MARK: - Launching

    /// Fire-and-forget launch of a machine.
    func launch(shortName: String) throws {
        try validateBinary()
        let process = Process()
        process.executableURL = binaryURL
        process.arguments = ["-rompath", romPath, shortName]
        do {
            try process.run()
        } catch {
            throw MAMEError.launchFailed(error.localizedDescription)
        }
    }

    // MARK: - Private process plumbing

    /// Runs the binary and captures stdout/stderr as raw Data. Both pipes are
    /// drained concurrently *before* `waitUntilExit()` to avoid a full-buffer
    /// deadlock on large output.
    private func runCapturingRaw(
        arguments: [String]
    ) async throws -> (out: Data, err: Data, status: Int32) {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<(out: Data, err: Data, status: Int32), Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = binaryURL
                process.arguments = arguments

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: MAMEError.launchFailed(error.localizedDescription))
                    return
                }

                var outData = Data()
                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.wait()
                process.waitUntilExit()

                continuation.resume(returning: (outData, errData, process.terminationStatus))
            }
        }
    }

    /// Text convenience over `runCapturingRaw`.
    private func runCapturing(
        arguments: [String]
    ) async throws -> (stdout: String, stderr: String, status: Int32) {
        let (out, err, status) = try await runCapturingRaw(arguments: arguments)
        return (String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self), status)
    }
}

// MARK: - SAX parser for machine years

/// Pulls `<year>` out of each `<machine>` (or legacy `<game>`) in `-listxml`
/// output without building a DOM — constant memory regardless of dump size.
final class MachineYearParser: NSObject, XMLParserDelegate {
    private(set) var years: [String: Int] = [:]

    private var currentMachine: String?
    private var capturingYear = false
    private var buffer = ""

    func parse(_ data: Data) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "machine", "game":
            currentMachine = attributeDict["name"]
        case "year":
            capturingYear = true
            buffer = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturingYear { buffer += string }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        switch elementName {
        case "year":
            if let name = currentMachine {
                // Strict: only clean 4-digit years (skip "19??", "198?", etc.).
                if let y = Int(buffer.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    years[name] = y
                }
            }
            capturingYear = false
        case "machine", "game":
            currentMachine = nil
        default:
            break
        }
    }
}
