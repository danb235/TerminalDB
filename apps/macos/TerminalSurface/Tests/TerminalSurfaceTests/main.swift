import AppKit
import SwiftTerm
import TerminalDBTerminal

// Integration assertions use synthetic text only. No profiles, network,
// pasteboard, credentials, or user terminal traces are read by this executable.
var checks = 0
var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    checks += 1
    if !condition() { failures += 1; print("FAIL: \(name)") }
}
_ = NSApplication.shared
func makeSurface(_ cols: Int = 40, _ rows: Int = 10) -> TDBTerminalSurface {
    let view = TDBTerminalSurface(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
    view.resizeGrid(columns: cols, rows: rows)
    return view
}
func native(_ view: TDBTerminalSurface) -> SwiftTerm.TerminalView {
    view.subviews[0] as! SwiftTerm.TerminalView
}
func term(_ view: TDBTerminalSurface) -> Terminal { native(view).terminal }
struct Cell: Equatable {
    let character: Character
    let width: Int8
    let attribute: Attribute
}
func cells(_ view: TDBTerminalSurface) -> [Cell] {
    (0..<view.terminalRows).flatMap { row in
        (0..<view.terminalColumns).map { col in
            let data = term(view).getCharData(col: col, row: row)!
            let character = term(view).getCharacter(for: data)
            return Cell(character: character == "\0" ? " " : character, width: data.width, attribute: data.attribute)
        }
    }
}
let esc = "\u{1b}"

do {
    let view = TDBTerminalSurface(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
    view.layoutSubtreeIfNeeded()
    check(native(view).frame == NSRect(x: 12, y: 0, width: 788, height: 388),
          "terminal content has top and left breathing room")
    view.frame.size = NSSize(width: 1000, height: 500)
    view.layoutSubtreeIfNeeded()
    check(native(view).frame == NSRect(x: 12, y: 0, width: 988, height: 488),
          "terminal content insets survive window resizing")
}

do {
    let view = makeSurface()
    view.feedText("界x\(esc)[2;5Hbox\(esc)[3;1H┌─┐\r\n│█│\r\n└─┘")
    check(term(view).getCharData(col: 0, row: 0)?.width == 2, "CJK occupies two cells")
    check(term(view).getCharacter(col: 2, row: 0) == "x", "CJK continuation isn't extra space")
    check(term(view).getCharacter(col: 4, row: 1) == "b", "absolute cursor positioning")
    check(term(view).getCharacter(col: 1, row: 3) == "█", "box/block glyph cell positioning")
    view.feedText("\(esc)[2;5H\(esc)[K")
    check(term(view).getCharacter(col: 4, row: 1) == "\0", "erase line removes existing cells")
    view.feedText("\(esc)[2;1Habcd\(esc)[2;2H\(esc)[P")
    check(term(view).getCharacter(col: 1, row: 1) == "c", "delete character shifts cells")
    view.feedText("\(esc)[@z")
    check(term(view).getCharacter(col: 1, row: 1) == "z" && term(view).getCharacter(col: 2, row: 1) == "c", "insert character shifts cells")
}

do {
    let replay = Data(("\(esc)[?2004h\(esc)[?1h\(esc)]0;Synthetic QA\u{7}" +
        "e\u{301} 界 🧪\r\n\(esc)[38;2;10;120;240mcolor\(esc)[0m\r\n" +
        "\(esc)[?1049h\(esc)[Htemporary\(esc)[?1049l" +
        "\(esc)[2;1H\(esc)[2Kfinal\(esc)[3;7H").utf8)
    let whole = makeSurface(), single = makeSurface(), chunks = makeSurface()
    whole.feedData(replay)
    for byte in replay { single.feedData(Data([byte])) }
    var i = 0
    while i < replay.count {
        let n = min(replay.count - i, i % 17 + 1)
        chunks.feedData(replay.subdata(in: i..<(i+n))); i += n
    }
    check(cells(whole) == cells(single) && cells(single) == cells(chunks), "fragmented UTF8/control sequences preserve exact cells and attributes")
    check(term(single).buffer.x == 6 && term(single).buffer.y == 2, "fragmented cursor position")
    check(single.applicationCursorKeys && single.bracketedPaste && !single.alternateScreenActive, "fragmented mode state")
}

do {
    let view = makeSurface(10, 5)
    view.feedText("0123456789X")
    check(term(view).buffer.y == 1 && term(view).getCharacter(col: 0, row: 1) == "X", "pending wrap occurs on next glyph")
    view.feedText("\(esc)[2;4r\(esc)[?6h\(esc)[1;1H!")
    check(term(view).getCharacter(col: 0, row: 1) == "!", "origin mode respects scroll margin")
    view.feedText("\(esc)[?6l\(esc)[r\(esc)[5;1H\(esc)7\(esc)[1;1H\(esc)8")
    check(term(view).buffer.y == 4 && term(view).buffer.x == 0, "saved cursor restores position")
}

do {
    let view = makeSurface()
    view.feedText("shell history\r\n\(esc)[?2004h\(esc)[?1h\(esc)[?1049hfull screen")
    check(view.alternateScreenActive && !view.string.contains("shell history"), "alternate screen isolates shell history")
    for (cols, rows) in [(80,24),(120,40),(60,18),(40,10)] {
        view.resizeGrid(columns: cols, rows: rows)
        view.feedText("\(esc)[2J\(esc)[H┌─┐\r\n│Q│\r\n└─┘")
        check(view.terminalColumns == cols && view.terminalRows == rows, "resize geometry \(cols)x\(rows)")
        check(view.bracketedPaste && view.applicationCursorKeys && view.alternateScreenActive, "resize doesn't soft-reset modes")
        check(view.string.components(separatedBy: "Q").count == 2, "resize redraw doesn't append ghost frames")
    }
    view.feedText("\(esc)[?1049l")
    check(view.string.contains("shell history") && !view.string.contains("│Q│"), "alternate exit restores normal buffer")
}

do {
    let view = makeSurface()
    view.feedText((0..<200).map { "synthetic line \($0)\r\n" }.joined())
    native(view).scroll(toPosition: 0.25)
    let top = term(view).getTopVisibleRow()
    check(!view.isAtBottom && top < 150, "scrollback moves away from live prompt")
    view.feedText("new output\r\n")
    check(term(view).getTopVisibleRow() == top, "streaming output doesn't steal scrollback position")
    view.scrollToBottom()
    check(view.isAtBottom, "return to live output")
}

do {
    let view = makeSurface(12, 5)
    view.feedText("unrelated\r\nhello world and wrap\r\n界text")
    let selection = native(view).selection!
    selection.setSoftStart(bufferPosition: Position(col: 0, row: 1))
    selection.startSelection()
    selection.dragExtend(bufferPosition: Position(col: 8, row: 2))
    check(view.selectionText == "hello world and wrap", "wrapped selection copies only selected logical text")
    selection.setSoftStart(bufferPosition: Position(col: 0, row: 3))
    selection.startSelection()
    selection.dragExtend(bufferPosition: Position(col: 2, row: 3))
    check(view.selectionText == "界", "wide-character selection excludes continuation padding")
}

do {
    let view = makeSurface(24, 5)
    view.feedText("selected text\r\nlive prompt")
    let selection = native(view).selection!
    selection.setSelection(start: Position(col: 0, row: 0),
                           end: Position(col: 13, row: 0))
    check(view.selectionText == "selected text", "selection fixture starts with expected text")
    view.feedText("\r\nlive redraw 1\r\nlive redraw 2")
    check(selection.active && view.selectionText == "selected text",
          "streaming TUI line feeds preserve the active selection for copy")
}

do {
    check(TDBTerminalSurface.droppedFileText(paths: ["/tmp/plain.txt"]) ==
              "/tmp/plain.txt ",
          "plain dropped path is inserted with a trailing separator")
    check(native(makeSurface()).registeredDraggedTypes.contains(.fileURL),
          "terminal registers as a native file-drop destination")
    check(TDBTerminalSurface.droppedFileText(paths: [
        "/tmp/project brief.md", "/tmp/Danny's notes.txt",
    ]) == "'/tmp/project brief.md' '/tmp/Danny'\\''s notes.txt' ",
          "multiple dropped paths are shell-safe and preserve drag order")

    let view = makeSurface()
    var fds = [Int32](repeating: -1, count: 2)
    check(pipe(&fds) == 0, "file-drop input test pipe")
    _ = fcntl(fds[0], F_SETFL, O_NONBLOCK)
    view.pty = fds[1]
    view.feedText("\(esc)[?2004h")
    view.insertDroppedFileURLs([
        URL(fileURLWithPath: "/tmp/project brief.md"),
        URL(fileURLWithPath: "/tmp/plain.txt"),
    ])
    var received = [UInt8](repeating: 0, count: 256)
    let count = read(fds[0], &received, received.count)
    let expected = Data(("\(esc)[200~'/tmp/project brief.md' " +
        "/tmp/plain.txt \(esc)[201~").utf8)
    check(count == expected.count &&
              Data(received.prefix(max(0, count))) == expected,
          "dropping files inserts complete bracketed-paste input into the TUI")
    view.pty = -1
    close(fds[0]); close(fds[1])
}

do {
    let view = makeSurface()
    view.feedText("previous secret-like synthetic history\r\n")
    view.beginCommandCapture()
    view.feedText("this command only\r\n")
    let output = view.endCommandCapture()
    check(output.contains("this command only") && !output.contains("previous"), "ledger capture excludes preceding command")
    check(!view.string.contains("EXIT") && !view.string.contains("SAVED"), "ledger never injects text into terminal")
    view.beginCommandCapture()
    view.feedText("before resize\r\n")
    view.resizeGrid(columns: 20, rows: 8)
    view.feedText("after resize\r\n")
    let resizedOutput = view.endCommandCapture()
    check(resizedOutput.contains("before resize") && resizedOutput.contains("after resize") && !resizedOutput.contains("previous"), "ledger boundaries survive reflow")
}

do {
    let source = makeSurface(40, 10), copy = makeSurface(40, 10)
    source.feedText((0..<30).map { "row \($0)\r\n" }.joined())
    source.feedText("\(esc)[2J\(esc)[H┌──┐\r\n│界│\r\n└──┘\(esc)[4;1H\(esc)[38;2;31;201;90mgreen\(esc)[0m\(esc)[?2004h\(esc)[?1h\(esc)[?25l")
    let expectedCells = cells(source)
    native(source).scroll(toPosition: 0)
    copy.feedText(source.ansiSnapshot())
    check(expectedCells == cells(copy), "remote snapshot restores live cells/colors not scrolled viewport")
    check(term(source).buffer.x == term(copy).buffer.x && term(source).buffer.y == term(copy).buffer.y, "remote cursor matches native")
    check(copy.bracketedPaste && copy.applicationCursorKeys && !copy.terminalCursorVisible, "remote input modes and cursor visibility")
    check(source.ansiSnapshot().utf8.count < 240000, "ordinary remote snapshot stays compact")
    let colored = makeSurface(), coloredCopy = makeSurface()
    colored.feedText("\(esc)[31mred")
    coloredCopy.feedText(colored.ansiSnapshot())
    colored.feedText("more"); coloredCopy.feedText("more")
    check(cells(colored) == cells(coloredCopy), "raw deltas retain snapshot's active color")
    let alternate = makeSurface(), alternateCopy = makeSurface()
    alternate.feedText("\(esc)[?1049hvim screen")
    alternateCopy.feedText(alternate.ansiSnapshot())
    check(alternateCopy.alternateScreenActive && cells(alternate) == cells(alternateCopy), "remote snapshot restores alternate buffer")
    for text in ["1234567890", "12345678界"] {
        let edge = makeSurface(10,5), edgeCopy = makeSurface(10,5)
        edge.feedText(text)
        edgeCopy.feedText(edge.ansiSnapshot())
        edge.feedText("Z"); edgeCopy.feedText("Z")
        check(cells(edge) == cells(edgeCopy), "snapshot restores pending wrap for \(text)")
    }
}

do {
    let source = makeSurface(500, 200), copy = makeSurface(500, 200)
    let row = (0..<500).map { index in
        "\(esc)[1;3;4;38;2;\(index % 256);120;240;48;2;10;\((index + 1) % 256);90mX"
    }.joined()
    source.feedText((0..<200).map { "\(esc)[\($0 + 1);1H" + row }.joined())
    let snapshot = source.ansiSnapshot()
    check(snapshot.utf16.count > 256000 && snapshot.utf16.count < 8 * 1024 * 1024, "maximum colored viewport fits bounded remote assembly")
    copy.feedText(snapshot)
    check(cells(source) == cells(copy), "maximum colored viewport is not truncated")
}

do {
    let view = makeSurface()
    var boundaries: [String] = []
    var title = ""
    view.commandBoundary = { boundaries.append($0) }
    view.titleChanged = { title = $0 }
    view.feedText("\(esc)]633;C\u{7}output\(esc)]633;D\(esc)\\\(esc)]0;QA title\u{7}")
    check(boundaries == ["C", "D"] && title == "QA title", "shell OSC callbacks preserve boundaries and title")
    check(view.string.contains("output") && !view.string.contains("633"), "shell integration never appears as screen text")
}

// Slow-reader backpressure regression: exact bytes and order, including paste
// delimiters and the Enter queued behind a 1 MB Unicode paste.
do {
    let view = makeSurface()
    var fds = [Int32](repeating: -1, count: 2)
    check(pipe(&fds) == 0, "input test pipe")
    _ = fcntl(fds[0], F_SETFL, O_NONBLOCK)
    _ = fcntl(fds[1], F_SETFL, O_NONBLOCK)
    view.pty = fds[1]
    native(view).insertText(NSAttributedString(string: "日本語"), replacementRange: NSRange(location: NSNotFound, length: 0))
    var committed = [UInt8](repeating: 0, count: 64)
    let committedCount = read(fds[0], &committed, committed.count)
    check(committedCount == "日本語".utf8.count && Data(committed.prefix(max(0, committedCount))) == Data("日本語".utf8), "attributed input-method commit is delivered")
    view.feedText("\(esc)[?2004h")
    for size in [5000, 65536, 1048576] {
        let payload = String(repeating: "界-line\n", count: size / 9 + 1)
        let expected = Data(("\(esc)[200~" + payload + "\(esc)[201~\r").utf8)
        view.pasteString(payload)
        _ = view.enqueueInputData(Data([13]))
        var received = Data()
        let deadline = Date().addingTimeInterval(10)
        while received.count < expected.count && Date() < deadline {
            var buffer = [UInt8](repeating: 0, count: 1537)
            let n = read(fds[0], &buffer, buffer.count)
            if n > 0 { received.append(contentsOf: buffer.prefix(n)) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.001))
        }
        check(received == expected, "exact Unicode paste and queued Enter under backpressure \(size) bytes")
    }
    view.pty = -1
    close(fds[0]); close(fds[1])
}

print("Terminal surface regression checks: \(checks - failures)/\(checks) passed")
exit(failures == 0 ? 0 : 1)
