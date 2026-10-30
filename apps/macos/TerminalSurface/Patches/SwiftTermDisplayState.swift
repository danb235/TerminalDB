// TerminalDB read-only display-state export for pinned SwiftTerm 1.19.0.
// Appended to Terminal.swift so private state stays inside its defining module.
// This changes no parsing, encryption, or terminal execution behavior.

public struct TerminalDBDisplayState {
    public let modes: String
    public let palette: String
    public let originRow: Int
    public let originColumn: Int
    public let savedModes: String
    public let savedX: Int
    public let savedY: Int
    public let savedAttribute: Attribute
    public let savedOriginRow: Int
    public let savedOriginColumn: Int
}

extension Terminal {
    public var terminalDBDisplayState: TerminalDBDisplayState {
        func mode(_ number: Int, _ enabled: Bool, dec: Bool = true) -> String {
            "\u{1b}[\(dec ? "?" : "")\(number)\(enabled ? "h" : "l")"
        }
        func cursorModes(origin: Bool, margins: Bool, wrap: Bool, reverse: Bool) -> String {
            var result = mode(6, origin) + mode(69, margins) + mode(7, wrap) + mode(45, reverse)
            if margins { result += "\u{1b}[\(buffer.marginLeft + 1);\(buffer.marginRight + 1)s" }
            return result
        }
        func charsetCode(_ mapping: [UInt8: String]?) -> UInt8 {
            guard let mapping else { return 66 }
            return CharSets.all.keys.sorted().first { CharSets.all[$0] == mapping } ?? 66
        }
        func designation(_ slot: Int, _ mapping: [UInt8: String]?) -> String {
            String(decoding: [0x1b, [UInt8]("()*+".utf8)[slot], charsetCode(mapping)], as: UTF8.self)
        }
        var modes = cursorModes(origin: originMode, margins: marginMode, wrap: wraparound, reverse: reverseWraparound)
        modes += mode(1, applicationCursor) + mode(66, applicationKeypad) + mode(5, reverseColors)
        modes += mode(4, insertMode, dec: false) + mode(20, lineFeedMode, dec: false)
        modes += mode(1004, sendFocus) + mode(1007, alternateScrollMode) + mode(2004, bracketedPasteMode)
        let mouse: Int
        switch mouseMode {
        case .off: mouse = 0
        case .x10: mouse = 9
        case .vt200: mouse = 1000
        case .buttonEventTracking: mouse = 1002
        case .anyEvent: mouse = 1003
        }
        if mouse != 0 { modes += mode(mouse, true) }
        switch mouseProtocol {
        case .x10: break
        case .utf8: modes += mode(1005, true)
        case .sgr: modes += mode(1006, true)
        case .urxvt: modes += mode(1015, true)
        case .sgrPixel: modes += mode(1016, true)
        }
        modes += "\u{1b}[>\(mouseShiftCapture ? 1 : 0)s"
        let style: Int
        switch options.cursorStyle {
        case .blinkBlock: style = 1
        case .steadyBlock: style = 2
        case .blinkUnderline: style = 3
        case .steadyUnderline: style = 4
        case .blinkBar: style = 5
        case .steadyBar: style = 6
        }
        modes += "\u{1b}[\(style) q"
        let keyboard = isCurrentBufferAlternate ? keyboardModeAlt : keyboardModeNormal
        for flags in keyboard.stack { modes += "\u{1b}[=\(flags.rawValue)u\u{1b}[>0u" }
        modes += "\u{1b}[=\(keyboard.flags.rawValue)u"
        let modeSettings = modes
        for slot in 0..<4 { modes += designation(slot, gCharsets[slot]) }
        switch gLevel {
        case 1: modes += "\u{e}"
        case 2: modes += "\u{1b}n"
        case 3: modes += "\u{1b}o"
        default: modes += "\u{f}"
        }
        // DECRC can restore a charset independently of the selected G slot.
        if charset != gCharsets[Int(gLevel)] { modes += "\u{1b}8" + modeSettings }
        var palette = ""
        for index in ansiColors.indices where ansiColors[index] != defaultAnsiColors[index] {
            palette += "\u{1b}]4;\(index);\(ansiColors[index].formatAsXcolor())\u{1b}\\"
        }
        return TerminalDBDisplayState(modes: modes, palette: palette,
            originRow: originMode ? buffer.scrollTop : 0,
            originColumn: originMode && marginMode ? buffer.marginLeft : 0,
            savedModes: cursorModes(origin: buffer.savedOriginMode, margins: buffer.savedMarginMode,
                                    wrap: buffer.savedWraparound, reverse: buffer.savedReverseWraparound) + designation(0, buffer.savedCharset) + "\u{f}",
            savedX: buffer.savedX, savedY: buffer.savedY, savedAttribute: buffer.savedAttr,
            savedOriginRow: buffer.savedOriginMode ? buffer.scrollTop : 0,
            savedOriginColumn: buffer.savedOriginMode && buffer.savedMarginMode ? buffer.marginLeft : 0)
    }
}

extension Terminal {
    public var terminalDBSnapshotReady: Bool { !parser.terminalDBPendingOverflow }
    public var terminalDBPendingInput: [UInt8] { parser.terminalDBPendingBytes + readingBuffer.putbackBuffer }
}
