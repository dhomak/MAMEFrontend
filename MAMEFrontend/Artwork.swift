import Foundation

/// A category of MAME support artwork. Each maps to progetto-SNAPS style
/// per-type containers (a folder, a `.zip`, or a `.7z`) — except `.bezel`,
/// which comes from per-game archives.
enum ArtworkKind: String, CaseIterable, Identifiable {
    case snapshot, title, marquee, cabinet, flyer, cover, bezel

    var id: String { rawValue }

    var label: String {
        switch self {
        case .snapshot: return "Snap"
        case .title:    return "Title"
        case .marquee:  return "Marquee"
        case .cabinet:  return "Cabinet"
        case .flyer:    return "Flyer"
        case .cover:    return "Cover"
        case .bezel:    return "Bezel"
        }
    }

    /// Container base names (folder or archive) searched in priority order.
    var containers: [String] {
        switch self {
        case .snapshot: return ["snap", "snaps"]
        case .title:    return ["title", "titles"]
        case .marquee:  return ["marquee", "marquees"]
        case .cabinet:  return ["cabinet", "cabinets", "cabdevs"]
        case .flyer:    return ["flyer", "flyers"]
        case .cover:    return ["cover", "covers"]
        case .bezel:    return []    // per-game <name>.zip / .7z
        }
    }
}

/// Resolves artwork bytes from extracted files, `.zip` (system `unzip`), or
/// `.7z` (system `7zz`/`7z`).
enum ArtworkStore {
    static let exts = ["png", "jpg", "jpeg"]

    // MARK: - Extracted files

    static func extractedFile(dir: URL, names: [String]) -> Data? {
        let fm = FileManager.default
        for name in names {
            for ext in exts {
                let url = dir.appendingPathComponent("\(name).\(ext)")
                if fm.fileExists(atPath: url.path), let data = try? Data(contentsOf: url) { return data }
            }
        }
        return nil
    }

    // MARK: - Archive dispatch (zip vs 7z)

    static func listEntries(archive: URL) -> Set<String> {
        archive.pathExtension.lowercased() == "7z" ? list7z(archive) : listZip(archive)
    }

    static func extractEntry(archive: URL, entry: String) -> Data? {
        archive.pathExtension.lowercased() == "7z" ? un7z(archive, entry) : unzip(archive, entry)
    }

    /// Finds an entry whose basename matches (tolerates a folder prefix).
    static func entry(in entries: Set<String>, matchingBasename base: String) -> String? {
        let target = base.lowercased()
        return entries.first { ($0 as NSString).lastPathComponent.lowercased() == target }
    }

    /// Best image inside a per-game archive: prefers `<name>.png`, then a
    /// bezel/background-named image, else the first image.
    static func bestImageEntry(in entries: Set<String>, preferNames: [String]) -> String? {
        let images = entries.filter { e in
            let l = e.lowercased()
            return l.hasSuffix(".png") || l.hasSuffix(".jpg") || l.hasSuffix(".jpeg")
        }.sorted()
        guard !images.isEmpty else { return nil }
        for name in preferNames {
            for ext in exts {
                let t = "\(name).\(ext)".lowercased()
                if let hit = images.first(where: { $0.lowercased() == t }) { return hit }
            }
        }
        for keyword in ["bezel", "background", "artwork", "_bg", "-bg"] {
            if let hit = images.first(where: { $0.lowercased().contains(keyword) }) { return hit }
        }
        return images.first
    }

    // MARK: - zip (Info-ZIP unzip)

    private static func listZip(_ archive: URL) -> Set<String> {
        guard let exe = unzipPath, let out = run(exe, ["-Z1", archive.path]) else { return [] }
        var set = Set<String>()
        String(decoding: out, as: UTF8.self).enumerateLines { line, _ in
            let n = line.trimmingCharacters(in: .whitespaces)
            if !n.isEmpty { set.insert(n) }
        }
        return set
    }

    private static func unzip(_ archive: URL, _ entry: String) -> Data? {
        guard let exe = unzipPath, let d = run(exe, ["-p", archive.path, entry]), !d.isEmpty else { return nil }
        return d
    }

    // MARK: - 7z (7zz / 7z / 7za)

    private static func list7z(_ archive: URL) -> Set<String> {
        // `-slt` prints a `Path = <entry>` line per file.
        guard let exe = sevenZipPath, let out = run(exe, ["l", "-slt", archive.path]) else { return [] }
        var set = Set<String>()
        String(decoding: out, as: UTF8.self).enumerateLines { line, _ in
            if line.hasPrefix("Path = ") {
                let n = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { set.insert(n) }
            }
        }
        return set
    }

    private static func un7z(_ archive: URL, _ entry: String) -> Data? {
        // `-so` writes the file to stdout; `-bso0 -bsp0` suppress log/progress so
        // stdout carries only the image bytes.
        guard let exe = sevenZipPath,
              let d = run(exe, ["e", "-so", "-bso0", "-bsp0", "-y", archive.path, entry]),
              !d.isEmpty
        else { return nil }
        return d
    }

    // MARK: - Tool paths

    private static var unzipPath: String? {
        firstExecutable(["/usr/bin/unzip", "/opt/homebrew/bin/unzip", "/usr/local/bin/unzip"])
    }

    /// Resolved once. Prefers a `7zz` bundled inside the app (self-contained),
    /// then a system install.
    private static let sevenZipPath: String? = resolveSevenZip()

    private static func resolveSevenZip() -> String? {
        // Bundled 7zz — Resources/7zz or MacOS/7zz.
        var candidates: [URL] = []
        if let r = Bundle.main.url(forResource: "7zz", withExtension: nil) { candidates.append(r) }
        if let macos = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(macos.appendingPathComponent("7zz"))
        }
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let ready = makeRunnable(url) { return ready }
        }
        // System fallback (Homebrew / p7zip).
        return firstExecutable(["/opt/homebrew/bin/7zz", "/usr/local/bin/7zz",
                                "/opt/homebrew/bin/7z", "/usr/local/bin/7z",
                                "/opt/homebrew/bin/7za", "/usr/local/bin/7za", "/usr/bin/7z"])
    }

    /// Returns a runnable path for a bundled binary. If it isn't executable in
    /// place (Xcode resource copies can drop the +x bit, and the bundle is
    /// read-only once installed/signed), copy it into Application Support once
    /// and mark it executable there.
    private static func makeRunnable(_ bundled: URL) -> String? {
        let fm = FileManager.default
        if fm.isExecutableFile(atPath: bundled.path) { return bundled.path }
        guard let support = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                        appropriateFor: nil, create: true) else { return nil }
        let dir = support.appendingPathComponent("MAMEFrontend", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("7zz")
        if !fm.isExecutableFile(atPath: dest.path) {
            try? fm.removeItem(at: dest)
            do {
                try fm.copyItem(at: bundled, to: dest)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            } catch { return nil }
        }
        return fm.isExecutableFile(atPath: dest.path) ? dest.path : nil
    }

    private static func firstExecutable(_ paths: [String]) -> String? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Process runner (drains both pipes concurrently)

    private static func run(_ exe: String, _ args: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do { try process.run() } catch { return nil }

        var outData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            _ = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.wait()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? outData : nil
    }
}
