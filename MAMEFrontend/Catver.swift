import Foundation

/// Parses `catver.ini` — specifically its `[Category]` section, which maps each
/// machine short name to a genre string like "Shooter / Flying Vertical".
enum CatverStore {

    /// Reads and indexes the file at `path`. Synchronous — call off-main.
    static func index(fromFileAt path: String) throws -> [String: String] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""

        var index: [String: String] = [:]
        var inCategory = false

        text.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Section header, e.g. [Category] or [VerAdded].
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                inCategory = (trimmed.lowercased() == "[category]")
                return
            }
            guard inCategory, !trimmed.isEmpty, !trimmed.hasPrefix(";") else { return }
            guard let eq = trimmed.firstIndex(of: "=") else { return }

            let name = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            let genre = String(trimmed[trimmed.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { index[name] = genre }
        }
        return index
    }
}
