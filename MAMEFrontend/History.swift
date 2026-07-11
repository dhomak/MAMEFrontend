import Foundation

/// The reference-text sources shown in the inspector, each a MAME `.dat` file.
enum InfoTab: String, CaseIterable, Identifiable {
    case history, mameinfo, command

    var id: String { rawValue }

    var label: String {
        switch self {
        case .history:  return "History"
        case .mameinfo: return "Info"
        case .command:  return "Commands"
        }
    }

    var fileHint: String {
        switch self {
        case .history:  return "history.xml / history.dat"
        case .mameinfo: return "mameinfo.dat"
        case .command:  return "command.dat"
        }
    }
}

/// Loads a History.dat-project file (modern `history.xml` or legacy
/// `history.dat`) into a `systemShortName → entry text` index.
enum HistoryStore {

    /// Reads and parses the file at `path`. Format is chosen by extension, then
    /// by sniffing for a leading `<`. Runs synchronously — call it off-main.
    static func index(fromFileAt path: String) throws -> [String: String] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let lower = path.lowercased()
        let isXML = lower.hasSuffix(".xml") || (!lower.hasSuffix(".dat") && sniffXML(data))

        if isXML {
            let parser = HistoryXMLParser()
            parser.parse(data)
            return parser.index
        } else {
            // history.dat is usually UTF-8 but older copies are Latin-1.
            let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""
            return parseDAT(text)
        }
    }

    /// True if the first non-whitespace byte looks like the start of XML.
    static func sniffXML(_ data: Data) -> Bool {
        for byte in data.prefix(256) {
            switch byte {
            case 0x20, 0x09, 0x0A, 0x0D: continue          // space, tab, LF, CR
            default: return byte == UInt8(ascii: "<")
            }
        }
        return false
    }

    /// Parses the shared MAME `.dat` grammar used by history.dat, mameinfo.dat,
    /// and command.dat:
    ///
    ///     $info=puckman,pacman
    ///     $bio                  ($cmd in command.dat, $mame in mameinfo.dat, …)
    ///     ...text...
    ///     $end
    ///
    /// A `$<tag>=names` line sets the current machine list. Any *other* `$` line
    /// (no `=`) is treated as a body marker — the marker name varies by file, so
    /// we don't hardcode it. `$end` flushes the body to every listed machine.
    static func parseDAT(_ content: String) -> [String: String] {
        var index: [String: String] = [:]
        var currentNames: [String] = []
        var capturing = false
        var buffer: [String] = []

        content.enumerateLines { line, _ in
            if line.hasPrefix("$") {
                if line.hasPrefix("$end") {
                    capturing = false
                    let text = buffer.joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        for name in currentNames { index[name] = text }
                    }
                    currentNames = []
                } else if let eq = line.firstIndex(of: "=") {
                    // "$info=name1,name2" (or "$mame=…" style headers)
                    let namesPart = line[line.index(after: eq)...]
                    let names = namesPart
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    if !names.isEmpty { currentNames = names }
                } else {
                    // Any other bare "$tag" line ($bio / $cmd / $mame / …) starts
                    // the body for the machines named above.
                    capturing = true
                    buffer = []
                }
            } else if capturing {
                buffer.append(line)
            }
        }
        return index
    }
}

/// SAX parser for `history.xml`:
///
///     <entry>
///       <systems><system name="puckman"/><system name="pacman"/></systems>
///       <text> ... </text>
///     </entry>
///
/// Software-list entries (`<item .../>`) are ignored; this targets arcade/system
/// machines matched by short name.
final class HistoryXMLParser: NSObject, XMLParserDelegate {
    private(set) var index: [String: String] = [:]

    private var inEntry = false
    private var currentSystems: [String] = []
    private var capturingText = false
    private var textBuffer = ""

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
        case "entry":
            inEntry = true
            currentSystems = []
            textBuffer = ""
        case "system":
            if inEntry, let name = attributeDict["name"] { currentSystems.append(name) }
        case "text":
            if inEntry { capturingText = true; textBuffer = "" }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturingText { textBuffer += string }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        switch elementName {
        case "text":
            capturingText = false
        case "entry":
            let text = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                for name in currentSystems { index[name] = text }
            }
            inEntry = false
            currentSystems = []
            textBuffer = ""
        default:
            break
        }
    }
}
