import Foundation

/// Resolves artwork bytes for a machine, from either extracted image files or
/// MAME artwork zips (`snap.zip`, `titles.zip`, …) via the system `unzip`.
enum ArtworkStore {
    static let subdirs = ["", "snap", "snaps", "titles", "title", "marquees", "covers"]
    static let zipNames = ["snap.zip", "snaps.zip", "titles.zip", "marquees.zip",
                           "cabinets.zip", "covers.zip", "flyers.zip"]
    static let exts = ["png", "jpg", "jpeg"]

    /// Looks for an extracted `<name>.<ext>` in the base folder / common subfolders.
    static func extractedFile(base: String, names: [String]) -> Data? {
        let baseURL = URL(fileURLWithPath: base)
        let fm = FileManager.default
        for name in names {
            for sub in subdirs {
                let dir = sub.isEmpty ? baseURL : baseURL.appendingPathComponent(sub)
                for ext in exts {
                    let url = dir.appendingPathComponent("\(name).\(ext)")
                    if fm.fileExists(atPath: url.path), let data = try? Data(contentsOf: url) {
                        return data
                    }
                }
            }
        }
        return nil
    }

    /// Lists entry names inside a zip (`unzip -Z1`). Cache the result per zip.
    static func listEntries(archive: URL) -> Set<String> {
        guard let out = runUnzip(["-Z1", archive.path]) else { return [] }
        var set = Set<String>()
        String(decoding: out, as: UTF8.self).enumerateLines { line, _ in
            let name = line.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { set.insert(name) }
        }
        return set
    }

    /// Extracts a single entry's bytes (`unzip -p`).
    static func unzipEntry(archive: URL, entry: String) -> Data? {
        guard let data = runUnzip(["-p", archive.path, entry]), !data.isEmpty else { return nil }
        return data
    }

    /// Finds an entry whose *basename* matches (case-insensitively), tolerating a
    /// folder prefix like `snap/mslug.png` or a `./mslug.png` from repacking.
    static func entry(in entries: Set<String>, matchingBasename base: String) -> String? {
        let target = base.lowercased()
        return entries.first { ($0 as NSString).lastPathComponent.lowercased() == target }
    }

    /// Chooses the most likely "main" image inside a per-game artwork zip:
    /// prefers `<name>.png/.jpg`, then a bezel/background-named image, else the
    /// first image alphabetically. Layout (`.lay`) and non-image files are ignored.
    static func bestImageEntry(in entries: Set<String>, preferNames: [String]) -> String? {
        let images = entries.filter { e in
            let l = e.lowercased()
            return l.hasSuffix(".png") || l.hasSuffix(".jpg") || l.hasSuffix(".jpeg")
        }.sorted()
        guard !images.isEmpty else { return nil }

        for name in preferNames {
            for ext in exts {
                let target = "\(name).\(ext)".lowercased()
                if let hit = images.first(where: { $0.lowercased() == target }) { return hit }
            }
        }
        for keyword in ["bezel", "background", "artwork", "_bg", "-bg"] {
            if let hit = images.first(where: { $0.lowercased().contains(keyword) }) { return hit }
        }
        return images.first
    }

    /// Runs `unzip` with the given args, draining both pipes concurrently.
    private static func runUnzip(_ args: [String]) -> Data? {
        let candidates = ["/usr/bin/unzip", "/opt/homebrew/bin/unzip", "/usr/local/bin/unzip"]
        guard let exe = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return nil }

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
