import SwiftUI

/// Renders command.dat move notation as arrows and button glyphs.
///
/// command.dat encodes inputs as escape tokens: `_` for common symbols
/// (`_2` ↓, `_P` punch, `_A`–`_D` SNK buttons), `^` for Capcom strengths and
/// charge directions (`^E` light punch, `^4` hold back), and `@…-button`
/// words for one-off game-specific buttons. Token semantics follow the
/// de-facto interpretation shared by existing frontends (Negatron, QMC2).
///
/// Capcom strengths are color-coded instead of spelled out: light / medium /
/// strong render as blue / orange / red — one glyph, no extra width, mirrors
/// the cabinet button colors.
enum CommandGlyphs {

    private static let light  = Color.blue
    private static let medium = Color.orange
    private static let strong = Color.red

    /// Plain `_` tokens with a fixed replacement.
    private static let underscore: [Character: String] = [
        // joystick, numpad notation
        "1": "↙", "2": "↓", "3": "↘",
        "4": "←",            "6": "→",
        "7": "↖", "8": "↑", "9": "↗",
        "N": "Ⓝ",           // neutral
        "?": "↔",           // any direction
        // buttons
        "A": "Ⓐ", "B": "Ⓑ", "C": "Ⓒ", "D": "Ⓓ",   // SNK
        "G": "Ⓖ",           // guard (Virtua Fighter)
        "H": "Ⓗ",           // hold (Dead or Alive)
        "P": "Ⓟ", "K": "Ⓚ", // generic punch / kick
        "S": "🅢",           // start
        "a": "①", "b": "②", "c": "③", "d": "④", "e": "⑤", "f": "⑥",
        // modifiers & move classes
        "+": "+",
        "^": "(air) ",       // move performed in the air
        "x": "↻360° ",       // full-circle on the stick
        "O": "hold ",        // hold the button
        "(": "[throw] ", ")": "[cmd] ", "@": "[special] ", "*": "[super] ",
        "&": "★", ">": "☆", "#": "[counter] ",
        "!": "⇢",            // chains into
        "`": "• ",
    ]

    /// `^1`–`^9`: charge directions (hold, then release). Double-struck
    /// arrows to distinguish from a plain press.
    private static let charge: [Character: String] = [
        "1": "⇙", "2": "⇓", "3": "⇘",
        "4": "⇐",            "6": "⇒",
        "7": "⇖", "8": "⇑", "9": "⇗",
    ]

    /// `@…` word tokens (game-specific buttons, Karate Champ second stick).
    private static let atWords: [(token: String, glyph: String)] = [
        ("@E-button", "Ⓔ"), ("@M-button", "Ⓜ"), ("@L-button", "Ⓛ"),
        ("@X-button", "Ⓧ"), ("@R-button", "Ⓡ"), ("@Y-button", "Ⓨ"),
        ("@O-button", "Ⓞ"), ("@F-button", "Ⓕ"), ("@J-button", "Ⓙ"),
        ("@W-button", "Ⓦ"),
        ("@left", "⬅"), ("@down", "⬇"), ("@right", "➡"), ("@up", "⬆"),
    ]

    /// True when the text uses Capcom strength or charge tokens, so the view
    /// knows to show the color legend.
    static func usesStrengths(_ text: String) -> Bool {
        for token in ["^E", "^F", "^G", "^H", "^I", "^J", "^U", "^T"]
        where text.contains(token) { return true }
        return false
    }

    static func render(_ text: String) -> AttributedString {
        var out = AttributedString()
        var plain = ""                       // batched unstyled run

        func flush() {
            guard !plain.isEmpty else { return }
            out += AttributedString(plain)
            plain = ""
        }
        func styled(_ s: String, _ color: Color) {
            flush()
            var a = AttributedString(s)
            a.foregroundColor = color
            out += a
        }
        func trio(_ glyph: String) {         // ^U / ^T: all three strengths
            styled(glyph, light); plain += "+"
            styled(glyph, medium); plain += "+"
            styled(glyph, strong)
        }

        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]

            if ch == "@", let (token, glyph) = atWords.first(where: {
                text[i...].hasPrefix($0.token)
            }) {
                plain += glyph
                i = text.index(i, offsetBy: token.count)
                continue
            }

            if ch == "^" || ch == "_" {
                let next = text.index(after: i)
                guard next < text.endIndex else { plain += String(ch); break }
                let code = text[next]
                var consumed = 2

                if ch == "^" {
                    switch code {
                    case "E": styled("Ⓟ", light)      // Capcom punches
                    case "F": styled("Ⓟ", medium)
                    case "G": styled("Ⓟ", strong)
                    case "H": styled("Ⓚ", light)      // Capcom kicks
                    case "I": styled("Ⓚ", medium)
                    case "J": styled("Ⓚ", strong)
                    case "U": trio("Ⓟ")
                    case "T": trio("Ⓚ")
                    case "W": plain += "Ⓟ+Ⓟ"
                    case "V": plain += "Ⓚ+Ⓚ"
                    case "M": plain += "MAX"           // SF Zero MAX super
                    case "S": plain += "🆂"            // select
                    case "s": plain += "Ⓢ"            // SamSho slash
                    case "*": plain += "(mash) "
                    case "!": plain += "↳"             // chains into (special)
                    default:
                        if let arrow = charge[code] { plain += arrow }
                        else { plain += String(ch); consumed = 1 }
                    }
                } else {                               // "_"
                    if code == "X" {                   // tap; swallow a ")"
                        let after = text.index(after: next)
                        if after < text.endIndex, text[after] == ")" {
                            plain += "tap)"; consumed = 3
                        } else {
                            plain += "tap "
                        }
                    } else if let glyph = underscore[code] {
                        plain += glyph
                    } else {
                        plain += String(ch); consumed = 1
                    }
                }
                i = text.index(i, offsetBy: consumed)
                continue
            }

            plain += String(ch)
            i = text.index(after: i)
        }
        flush()
        return out
    }
}
