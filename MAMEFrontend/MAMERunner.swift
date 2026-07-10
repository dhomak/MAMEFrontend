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
    /// names and SAX-parses year, manufacturer, and driver status of each. The
    /// caller chunks large sets and caches results — this metadata is static.
    func meta(for names: [String]) async throws -> [String: MachineMeta] {
        guard !names.isEmpty else { return [:] }
        try validateBinary()
        let (out, err, status) = try await runCapturingRaw(arguments: ["-listxml"] + names)
        guard status == 0 || !out.isEmpty else {
            throw MAMEError.nonZeroExit(status, String(decoding: err, as: UTF8.self))
        }
        let parser = MachineMetaParser()
        parser.parse(out)
        return parser.metas
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

    /// Launches a machine and monitors it. A successful launch keeps running for
    /// the whole play session (returns nil when the user later quits cleanly). A
    /// *failed* launch exits quickly with a non-zero code — in that case the
    /// captured stderr (MAME's error) is returned. Blocking work runs on a GCD
    /// thread, not the async pool.
    func launchMonitored(shortName: String, extraArgs: [String] = []) async throws -> String? {
        try validateBinary()
        let exe = binaryURL
        let workingDir = exe.deletingLastPathComponent()
        let args = ["-rompath", romPath] + extraArgs + [shortName]
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<String?, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = exe
                process.arguments = args
                // MAME resolves diff/, cfg/, nvram/, etc. relative to the working
                // directory — match a CLI run from the MAME folder.
                process.currentDirectoryURL = workingDir
                let errPipe = Pipe()
                process.standardError = errPipe
                process.standardOutput = FileHandle.nullDevice

                let start = Date()
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: MAMEError.launchFailed(error.localizedDescription))
                    return
                }
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let elapsed = Date().timeIntervalSince(start)

                // Only treat a *quick* non-zero exit as a launch failure; a long
                // session that later exits non-zero isn't a "failed to start".
                if process.terminationStatus != 0 && elapsed < 20 {
                    let raw = String(decoding: errData, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: raw.isEmpty
                        ? "MAME exited with code \(process.terminationStatus)."
                        : raw)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Splits a launch-option string into argv, respecting double-quoted spans
    /// so a quoted value with spaces stays one argument.
    static func tokenize(_ string: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for ch in string {
            if ch == "\"" {
                inQuotes.toggle()
            } else if ch == " " && !inQuotes {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
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
                process.currentDirectoryURL = binaryURL.deletingLastPathComponent()

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

// MARK: - SAX parser for machine metadata

/// Static per-machine metadata pulled from `-listxml`.
struct MachineMeta: Codable, Hashable {
    var year: Int = 0
    var manufacturer: String = ""
    var status: String = ""      // driver status: good / imperfect / preliminary
    var isBios: Bool = false
    var isDevice: Bool = false
    var isMechanical: Bool = false
    var isSystem: Bool = false   // has a <softwarelist> => computer / console
    var diskNames: [String] = [] // required (non-optional, dumped) CHD base names

    /// Not an arcade game (BIOS, device, mechanical, or software-consuming system).
    var nonGame: Bool { isBios || isDevice || isMechanical || isSystem }
    var requiresDisk: Bool { !diskNames.isEmpty }
}

/// Pulls `<year>`, `<manufacturer>`, and the `<driver status>` attribute out of
/// each `<machine>` (or legacy `<game>`) in `-listxml` — SAX, constant memory.
final class MachineMetaParser: NSObject, XMLParserDelegate {
    private(set) var metas: [String: MachineMeta] = [:]

    private var currentMachine: String?
    private var current = MachineMeta()
    private var capturing: String?    // "year" | "manufacturer" | nil
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
            current = MachineMeta()
            if attributeDict["isbios"] == "yes" { current.isBios = true }
            if attributeDict["isdevice"] == "yes" { current.isDevice = true }
            if attributeDict["runnable"] == "no" { current.isDevice = true }
            if attributeDict["ismechanical"] == "yes" { current.isMechanical = true }
        case "softwarelist":
            current.isSystem = true
        case "disk":
            // A required disk that should be dumped (skip optional / nodump).
            if attributeDict["optional"] != "yes", attributeDict["status"] != "nodump",
               let name = attributeDict["name"] {
                current.diskNames.append(name)
            }
        case "year":
            capturing = "year"; buffer = ""
        case "manufacturer":
            capturing = "manufacturer"; buffer = ""
        case "driver":
            if let s = attributeDict["status"] { current.status = s }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing != nil { buffer += string }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        switch elementName {
        case "year":
            // Strict: only clean 4-digit years (skip "19??", "198?", etc.).
            if let y = Int(buffer.trimmingCharacters(in: .whitespacesAndNewlines)) {
                current.year = y
            }
            capturing = nil
        case "manufacturer":
            current.manufacturer = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            capturing = nil
        case "machine", "game":
            if let name = currentMachine { metas[name] = current }
            currentMachine = nil
        default:
            break
        }
    }
}
