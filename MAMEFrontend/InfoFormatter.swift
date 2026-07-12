import SwiftUI

/// A parsed block of a MAME `.dat` entry.
enum InfoBlock: Identifiable {
    case heading(String)              // "- TRIVIA -"  → TRIVIA
    case field(key: String, value: String)   // "Players: 2"
    case paragraph(String)            // prose
    case preformatted(String)         // move lists / anything alignment-sensitive

    var id: String {
        switch self {
        case .heading(let s):            return "h:\(s)"
        case .field(let k, let v):       return "f:\(k):\(v)"
        case .paragraph(let s):          return "p:\(s.prefix(48))\(s.count)"
        case .preformatted(let s):       return "c:\(s.prefix(48))\(s.count)"
        }
    }
}

enum InfoFormatter {

    /// Splits an entry into typed blocks. `preformatOnly` (command.dat) keeps
    /// everything monospaced, since move lists depend on alignment.
    static func blocks(from text: String, preformatOnly: Bool) -> [InfoBlock] {
        let lines = text.components(separatedBy: .newlines)
        if preformatOnly {
            return preformattedBlocks(lines)
        }

        var blocks: [InfoBlock] = []
        var paragraph: [String] = []

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph = []
        }

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)

            if line.isEmpty {
                flushParagraph()
                continue
            }
            if let heading = headingText(line) {
                flushParagraph()
                blocks.append(.heading(heading))
                continue
            }
            if let (key, value) = fieldPair(line) {
                flushParagraph()
                blocks.append(.field(key: key, value: value))
                continue
            }
            // Keep the source's line breaks (lists, code tables, credits) unless
            // the line is clearly a wrapped continuation of the previous prose.
            if let previous = paragraph.last, isContinuation(of: previous, line) {
                paragraph[paragraph.count - 1] = previous + " " + line
            } else {
                paragraph.append(line)
            }
        }
        flushParagraph()
        return blocks
    }

    /// True when `line` looks like the tail of a sentence wrapped from `previous`
    /// — the previous line didn't close a sentence and this one starts lowercase.
    /// Anything else (a new sentence, a numbered code, a bullet) keeps its break.
    static func isContinuation(of previous: String, _ line: String) -> Bool {
        guard let lastChar = previous.last, let firstChar = line.first else { return false }
        if ".!?:;".contains(lastChar) { return false }
        guard firstChar.isLetter else { return false }
        return firstChar.isLowercase
    }

    /// `- TRIVIA -` / `-TRIVIA-` → "TRIVIA". Nil if the line isn't a section header.
    static func headingText(_ line: String) -> String? {
        guard line.hasPrefix("-"), line.hasSuffix("-"), line.count > 2 else { return nil }
        let inner = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        // Avoid catching bullet lines or dashes; headers are short and wordy.
        guard !inner.isEmpty, inner.count <= 40, inner.rangeOfCharacter(from: .letters) != nil
        else { return nil }
        return inner
    }

    /// "Players: 2" → ("Players", "2"). Deliberately strict: the colon must not
    /// be preceded by a space, the key must be short and label-like, and the
    /// value bounded — so "Kombat Zones : 002-003 - ..." (a list) and ordinary
    /// prose containing a colon stay paragraphs.
    static func fieldPair(_ line: String) -> (String, String)? {
        guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { return nil }
        let beforeColon = line[line.index(before: colon)]
        guard beforeColon != " " else { return nil }

        let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !value.isEmpty,
              key.count <= 24,
              key.split(separator: " ").count <= 3,
              value.count <= 120,
              key.rangeOfCharacter(from: .letters) != nil
        else { return nil }
        return (key, value)
    }

    /// Groups lines into monospaced chunks separated by blank lines, so a move
    /// list keeps its internal alignment but still breathes between sections.
    private static func preformattedBlocks(_ lines: [String]) -> [InfoBlock] {
        var blocks: [InfoBlock] = []
        var chunk: [String] = []

        func flush() {
            while let first = chunk.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
                chunk.removeFirst()
            }
            while let last = chunk.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                chunk.removeLast()
            }
            guard !chunk.isEmpty else { return }
            // A lone short line that reads like a header still gets to be one.
            if chunk.count == 1, let heading = headingText(chunk[0].trimmingCharacters(in: .whitespaces)) {
                blocks.append(.heading(heading))
            } else {
                blocks.append(.preformatted(chunk.joined(separator: "\n")))
            }
            chunk = []
        }

        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            } else {
                chunk.append(line)
            }
        }
        flush()
        return blocks
    }
}

/// Renders parsed `.dat` blocks with real typographic structure.
struct InfoTextView: View {
    let text: String
    let preformatOnly: Bool
    var commandGlyphs: Bool = false

    private var blocks: [InfoBlock] {
        InfoFormatter.blocks(from: text, preformatOnly: preformatOnly)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { block in
                switch block {
                case .heading(let title):
                    Text(title.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .kerning(0.8)
                        .padding(.top, 4)

                case .field(let key, let value):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(key)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(value)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                case .paragraph(let body):
                    Text(body)
                        .font(.callout)
                        .lineSpacing(2)
                        .lineLimit(nil)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                case .preformatted(let body):
                    Text(commandGlyphs ? CommandGlyphs.render(body) : AttributedString(body))
                        .font(.system(.caption, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.secondary.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 5))
                }
            }
            if commandGlyphs, CommandGlyphs.usesStrengths(text) {
                strengthLegend
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Shown only when the entry uses Capcom strength tokens.
    private var strengthLegend: some View {
        HStack(spacing: 8) {
            Text("Ⓟ/Ⓚ").foregroundStyle(.secondary)
            Text("light").foregroundStyle(.blue)
            Text("medium").foregroundStyle(.orange)
            Text("strong").foregroundStyle(.red)
            Text("·").foregroundStyle(.secondary)
            Text("⇐ charge (hold)").foregroundStyle(.secondary)
        }
        .font(.caption2)
        .padding(.top, 2)
    }
}
