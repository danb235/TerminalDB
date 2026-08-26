import Foundation
import SwiftTerm

// Serializes cells, not renderer glyph offsets. In particular a double-width
// character's continuation cell must not become an extra space in xterm.
enum TerminalSnapshot {
    static func sgr(_ attr: Attribute) -> String {
        var codes = ["0"]
        for (style, code): (CharacterStyle, String) in [(.bold, "1"), (.dim, "2"), (.italic, "3"), (.underline, "4"), (.blink, "5"), (.inverse, "7"), (.invisible, "8"), (.crossedOut, "9")] {
            if attr.style.contains(style) { codes.append(code) }
        }
        func color(_ value: Attribute.Color, foreground: Bool) -> String {
            let prefix = foreground ? "38" : "48"
            switch value {
            case .ansi256(let code): return "\(prefix);5;\(code)"
            case .trueColor(let r, let g, let b): return "\(prefix);2;\(r);\(g);\(b)"
            case .defaultColor: return foreground ? "39" : "49"
            case .defaultInvertedColor: return foreground ? "39" : "49"
            }
        }
        codes += [color(attr.fg, foreground: true), color(attr.bg, foreground: false)]
        return "\u{1b}[" + codes.joined(separator: ";") + "m"
    }

    static func encode(_ term: Terminal, cursorVisible: Bool, lineCount: Int) -> String {
        let base = max(0, lineCount - term.rows)
        // Bound retained history, but never truncate a live viewport to fit the
        // old text renderer's budget. The browser accepts up to 8 MiB, including
        // a maximum-size grid with per-cell true colors.
        var lines: [(row: Int, text: String)] = []
        var bytes = 0
        for row in stride(from: lineCount - 1, through: 0, by: -1) {
            guard let line = term.bufferLine(atRow: row) else { continue }
            var encoded = ""
            var previous: Attribute?
            for col in 0..<min(term.cols, line.count) {
                let cell = line[col]
                if cell.width == 0 { continue }
                if previous != cell.attribute {
                    encoded += sgr(cell.attribute)
                    previous = cell.attribute
                }
                let character = term.getCharacter(for: cell)
                encoded.append(character == "\0" ? " " : character)
            }
            if row < base && bytes + encoded.utf8.count > 220000 { break }
            lines.append((row, encoded)); bytes += encoded.utf8.count + 2
        }
        var result = term.isCurrentBufferAlternate ? "\u{1b}[?1049h" : ""
        result += "\u{1b}[0m\u{1b}[2J\u{1b}[H"
        for (index, entry) in lines.reversed().enumerated() {
            if index > 0, term.bufferLine(atRow: entry.row)?.isWrapped != true {
                result += "\r\n"
            }
            result += entry.text
        }
        // Keep this suffix compatible with adaptSnapshotToLocalViewport.
        result += "\u{1b}[?1\(term.applicationCursor ? "h" : "l")"
        result += "\u{1b}[?2004\(term.bracketedPasteMode ? "h" : "l")"
        result += "\u{1b}[\(term.buffer.scrollTop + 1);\(term.buffer.scrollBottom + 1)r"
        // CUP alone cannot restore a wrap-pending cursor. Repaint the final
        // glyph after positioning it so the next raw byte wraps, not overwrites.
        var cursorColumn = min(term.cols - 1, term.buffer.x)
        var wrapTail = ""
        if term.buffer.x >= term.cols,
           let line = term.bufferLine(atRow: base + term.buffer.y) {
            while cursorColumn > 0 && line[cursorColumn].width == 0 { cursorColumn -= 1 }
            let cell = line[cursorColumn]
            let glyph = term.getCharacter(for: cell)
            wrapTail = sgr(cell.attribute) + String(glyph == "\0" ? " " : glyph)
        }
        result += "\u{1b}[0m\u{1b}[\(term.buffer.y + 1);\(cursorColumn + 1)H"
        result += "\u{1b}[?25\(cursorVisible ? "h" : "l")"
        result += wrapTail
        // Raw PTY deltas resume after the snapshot, sometimes mid-color run.
        result += sgr(term.currentAttribute)
        return result
    }
}
