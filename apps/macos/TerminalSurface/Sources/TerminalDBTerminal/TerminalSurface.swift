import AppKit
import SwiftTerm

private func terminalColor(_ color: NSColor) -> Color {
    let rgb = color.usingColorSpace(.deviceRGB) ?? .white
    return Color(red: UInt16(rgb.redComponent * 65535), green: UInt16(rgb.greenComponent * 65535), blue: UInt16(rgb.blueComponent * 65535))
}

// The service uses the UI-independent SwiftTerm engine. The shared product
// adapter can still expose its existing APIs without rendering a hidden view.
private final class HostedTerminalEngine: TerminalDelegate {
    weak var owner: TDBTerminalSurface?
    var terminal: Terminal!
    init(owner: TDBTerminalSurface) {
        self.owner = owner
        terminal = Terminal(delegate: self, options: TerminalOptions(scrollback: 10000))
        terminal.foregroundColor = terminalColor(owner.textColor)
        terminal.backgroundColor = terminalColor(owner.backgroundColor)
        if let palette = owner.installedPalette { terminal.installPalette(colors: palette) }
        terminal.registerOscHandler(code: 633) { [weak owner] bytes in
            owner?.commandBoundary?(String(decoding: bytes, as: UTF8.self))
        }
    }
    func showCursor(source: Terminal) { owner?.terminalCursorVisible = true }
    func hideCursor(source: Terminal) { owner?.terminalCursorVisible = false }
    func setTerminalTitle(source: Terminal, title: String) { owner?.titleChanged?(title) }
    func send(source: Terminal, data: ArraySlice<UInt8>) {
        _ = owner?.enqueueInputData(Data(data))
    }
    func sizeChanged(source: Terminal) { owner?.gridSizeChanged?() }
}

// The emulator, renderer, selection and scrollback belong to SwiftTerm. This
// adapter owns only TerminalDB's PTY transport and product integration.
private final class SurfaceView: SwiftTerm.TerminalView {
    weak var owner: TDBTerminalSurface?
    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        // The session host alone answers device/status queries. A second
        // renderer must never inject duplicate replies into the shell. Mouse,
        // keyboard and focus events outside output parsing still reach the host.
        guard owner?.viewer != true || owner?.feedingTerminalOutput != true else { return }
        if owner?.viewer == true, let handler = owner?.focusHandler,
           data.elementsEqual([0x1b, 0x5b, 0x49]) || data.elementsEqual([0x1b, 0x5b, 0x4f]) {
            if owner?.inputEnabled == true { handler(data.last == 0x49) }
            return
        }
        super.send(source: source, data: data)
    }
    override func insertText(_ string: Any, replacementRange: NSRange) {
        // Cocoa input methods may commit attributed text; SwiftTerm's public
        // insertion path expects a string. Keep composition in the native view.
        super.insertText((string as? NSAttributedString)?.string ?? string,
                         replacementRange: replacementRange)
    }
    override func paste(_ sender: Any) {
        owner?.pasteString(NSPasteboard.general.string(forType: .string) ?? "")
    }
    override func linefeed(source: Terminal) {
        // SwiftTerm's macOS view normally clears the selection on every line
        // feed whenever mouse reporting is allowed. Interactive TUIs such as
        // Claude redraw often, so the selection disappears before Command-C
        // can copy it. TerminalDB still supports mouse reporting; it simply
        // keeps a local text selection alive while output continues.
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFileURLs(from: sender).isEmpty ? [] : .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !droppedFileURLs(from: sender).isEmpty
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedFileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        owner?.insertDroppedFileURLs(urls)
        return true
    }
    private func droppedFileURLs(from sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        return (sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: options) ?? []).compactMap {
                ($0 as? NSURL).map { $0 as URL }
            }.filter(\.isFileURL)
    }
    override func showCursor(source: Terminal) {
        owner?.terminalCursorVisible = true
        super.showCursor(source: source)
    }
    override func hideCursor(source: Terminal) {
        owner?.terminalCursorVisible = false
        super.hideCursor(source: source)
    }
}

@objc(TDBTerminalSurface)
public final class TDBTerminalSurface: NSView, TerminalViewDelegate {
    private static let contentInsetTop: CGFloat = 12
    private static let contentInsetLeft: CGFloat = 12
    private let surface: SurfaceView
    private var hostedEngine: HostedTerminalEngine?
    private var pinnedGrid: (Int, Int)?
    private var engine: Terminal { hostedEngine?.terminal ?? surface.terminal }
    private var pendingInput = Data()
    private var inputOffset = 0
    private var writeSource: DispatchSourceWrite?
    private var keyMonitor: Any?
    private var commandStartLine: BufferLine?
    private var commandStartColumn = 0
    private var commandStartRow = 0
    private var commandStartTrimmed = 0

    @objc public var pty: Int32 = -1 {
        didSet {
            guard oldValue != pty else { return }
            writeSource?.cancel()
            writeSource = nil
            pendingInput.removeAll(keepingCapacity: false)
            inputOffset = 0
        }
    }
    fileprivate var feedingTerminalOutput = false
    fileprivate var installedPalette: [Color]?
    @objc public var inputEnabled = true { didSet { surface.allowMouseReporting = inputEnabled } }
    @objc public var headless = false {
        didSet {
            guard oldValue != headless else { return }
            let cols = engine.cols, rows = engine.rows
            hostedEngine = headless ? HostedTerminalEngine(owner: self) : nil
            engine.resize(cols: cols, rows: rows)
        }
    }
    @objc public var viewer = false
    @objc public var inputHandler: ((Data) -> Bool)?
    @objc public var focusHandler: ((Bool) -> Void)?
    @objc public fileprivate(set) var terminalCursorVisible = true
    @objc public var userDidSendInput: (() -> Void)?
    @objc public var pasteDidSend: ((UInt, UInt) -> Void)?
    @objc public var cycleRegionsHandler: (() -> Void)?
    @objc public var titleChanged: ((String) -> Void)?
    @objc public var commandBoundary: ((String) -> Void)?
    @objc public var gridSizeChanged: (() -> Void)?
    @objc public var inputFailed: (() -> Void)?

    @objc public override init(frame: NSRect) {
        surface = SurfaceView(frame: frame, font: nil,
                              options: TerminalOptions(scrollback: 10000))
        super.init(frame: frame)
        wantsLayer = true
        surface.autoresizingMask = []
        surface.owner = self
        surface.terminalDelegate = self
        surface.registerForDraggedTypes([.fileURL])
        addSubview(surface)
        layoutTerminalSurface()
        engine.registerOscHandler(code: 633) { [weak self] bytes in
            self?.commandBoundary?(String(decoding: bytes, as: UTF8.self))
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window,
                  self.window?.firstResponder === self.surface else { return event }
            return self.handleSpecialKey(event) ? nil : event
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit {
        writeSource?.cancel()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }
    public override var acceptsFirstResponder: Bool { true }
    public override func layout() {
        super.layout()
        layoutTerminalSurface()
    }
    private func layoutTerminalSurface() {
        surface.frame = NSRect(
            x: bounds.minX + Self.contentInsetLeft,
            y: bounds.minY,
            width: max(1, bounds.width - Self.contentInsetLeft),
            height: max(1, bounds.height - Self.contentInsetTop))
        if let (cols, rows) = pinnedGrid, !headless, (engine.cols != cols || engine.rows != rows) {
            engine.resize(cols: cols, rows: rows)
            surface.sizeChanged(source: engine)
        }
    }
    public override func becomeFirstResponder() -> Bool {
        window?.makeFirstResponder(surface) ?? false
    }
    public override func keyDown(with event: NSEvent) {
        if !handleSpecialKey(event) { surface.keyDown(with: event) }
    }
    private func handleSpecialKey(_ event: NSEvent) -> Bool {
        guard inputEnabled else { return true }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 97 { cycleRegionsHandler?(); return true } // F6
        // Claude's documented multiline convention, without a shell-level remap.
        if [UInt16(36), 76].contains(event.keyCode), flags == .shift {
            sendUserData(Data([0x1b, 0x0d]))
            return true
        }
        return false
    }

    @objc public var font: NSFont {
        get { surface.font }
        set { surface.font = newValue }
    }
    @objc public var textColor: NSColor {
        get { surface.nativeForegroundColor }
        set { surface.nativeForegroundColor = newValue; hostedEngine?.terminal.foregroundColor = terminalColor(newValue) }
    }
    @objc public var backgroundColor: NSColor {
        get { surface.nativeBackgroundColor }
        set {
            surface.nativeBackgroundColor = newValue
            hostedEngine?.terminal.backgroundColor = terminalColor(newValue)
            layer?.backgroundColor = newValue.cgColor
        }
    }
    @objc public var terminalCursorColor: NSColor {
        get { surface.caretColor }
        set { surface.caretColor = newValue }
    }
    @objc public var selectionColor: NSColor {
        get { surface.selectedTextBackgroundColor }
        set { surface.selectedTextBackgroundColor = newValue }
    }
    @objc public func installANSIColors(_ colors: [NSColor]) {
        guard colors.count == 16 else { return }
        let palette = colors.map(terminalColor)
        installedPalette = palette; surface.installColors(palette)
        hostedEngine?.terminal.installPalette(colors: palette)
    }
    @objc public var terminalRows: Int { engine.rows }
    @objc public var terminalColumns: Int { engine.cols }
    @objc public var bracketedPaste: Bool { engine.bracketedPasteMode }
    @objc public var applicationCursorKeys: Bool { engine.applicationCursor }
    @objc public var alternateScreenActive: Bool { engine.isCurrentBufferAlternate }
    @objc public var selectionText: String { surface.getSelection() ?? "" }
    @objc public var hasKeyboardFocus: Bool { window?.firstResponder === surface }
    @objc public var string: String {
        engine.getText(start: Position(col: 0, row: 0),
            end: Position(col: terminalColumns, row: lineCount - 1))
    }
    private var lineCount: Int {
        // BufferLine identities expose the complete bounded buffer without
        // depending on SwiftTerm's internal yBase or circular-array storage.
        var low = 0, high = 10000 + terminalRows + 1
        let trimmed = engine.buffer.totalLinesTrimmed
        while low < high {
            let mid = (low + high) / 2
            if engine.getScrollInvariantLine(row: trimmed + mid) != nil { low = mid + 1 }
            else { high = mid }
        }
        return max(1, low)
    }
    @objc public func feedData(_ data: Data) {
        precondition(Thread.isMainThread)
        feedingTerminalOutput = true; defer { feedingTerminalOutput = false }
        if let hostedEngine {
            hostedEngine.terminal.feed(buffer: Array(data)[...])
            return
        }
        let selectedText = surface.selection.active
            ? surface.selection.getSelectedText()
            : nil
        surface.feed(byteArray: Array(data)[...])
        // SwiftTerm clears selection when its internal scroller is relaid out.
        // Streaming output can trigger that layout even when the window did
        // not move. Restore only when the exact selected text is still at the
        // same translated range; if a TUI genuinely overwrote it, leave the
        // selection cleared instead of highlighting unrelated content.
        if let selectedText, !selectedText.isEmpty,
           !surface.selection.active,
           surface.selection.getSelectedText() == selectedText {
            surface.selection.active = true
        }
    }
    @objc public func feedText(_ text: String) { feedData(Data(text.utf8)) }
    @objc public func resizeGrid(columns: Int, rows: Int) {
        // TerminalView.resize performs a soft reset: that would lose bracketed
        // paste and application cursor modes on every remote resize.
        if viewer { pinnedGrid = (max(2, columns), max(2, rows)) }
        engine.resize(cols: max(2, columns), rows: max(2, rows))
        if headless { gridSizeChanged?(); return }
        surface.sizeChanged(source: engine)
        surface.needsDisplay = true
    }
    @objc public func useLocalGrid() {
        // Recompute from this view's font and bounds when it takes control.
        // SwiftTerm's frame-size path preserves terminal modes.
        pinnedGrid = nil
        surface.setFrameSize(surface.frame.size)
    }
    @objc public func setTerminalFocus(_ focused: Bool) { engine.setTerminalFocus(focused) }
    @objc public func scrollToBottom() { surface.scroll(toPosition: 1) }
    @objc public var isAtBottom: Bool { !surface.canScroll || surface.scrollPosition >= 0.999 }
    @objc public func visibleText() -> String {
        let top = engine.getTopVisibleRow()
        return engine.getText(start: Position(col: 0, row: top),
            end: Position(col: terminalColumns, row: top + terminalRows - 1))
    }
    @objc public var snapshotReady: Bool { engine.terminalDBSnapshotReady }
    @objc public func ansiSnapshotData() -> Data {
        var data = Data(ansiSnapshot().utf8)
        data.append(contentsOf: engine.terminalDBPendingInput)
        return data
    }
    @objc public func ansiSnapshot() -> String {
        TerminalSnapshot.encode(engine, cursorVisible: terminalCursorVisible, lineCount: lineCount)
    }
    @objc public func beginCommandCapture() {
        let term = engine
        let row = max(0, lineCount - term.rows) + term.buffer.y
        commandStartLine = term.bufferLine(atRow: row)
        commandStartRow = row
        commandStartTrimmed = term.buffer.totalLinesTrimmed
        commandStartColumn = term.buffer.x
    }
    @objc public func endCommandCapture() -> String {
        let term = engine
        let trimmed = term.buffer.totalLinesTrimmed - commandStartTrimmed
        guard let line = commandStartLine else { return "" }
        // A recycled BufferLine can have the same identity as an evicted row.
        let start: Int? = trimmed <= commandStartRow
            ? (0..<lineCount).first { term.bufferLine(atRow: $0) === line }
            : nil
        commandStartLine = nil
        // If reflow/clear destroyed the marker, never accidentally capture an
        // earlier command. Trimming past the start is safe: every retained row
        // then belongs to this command (bounded by the scrollback capacity).
        guard start != nil || trimmed > commandStartRow else { return "" }
        let end = max(0, lineCount - term.rows) + term.buffer.y
        return term.getText(start: Position(col: start == nil ? 0 : commandStartColumn, row: start ?? 0),
                            end: Position(col: term.buffer.x, row: end))
    }
    @objc public func pasteString(_ text: String) {
        guard inputEnabled, !text.isEmpty else { return }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let bytes = bracketedPaste
            ? Data(("\u{1b}[200~" + normalized + "\u{1b}[201~").utf8)
            : Data(normalized.replacingOccurrences(of: "\n", with: "\r").utf8)
        if sendUserData(bytes) {
            pasteDidSend?(UInt(normalized.utf8.count), UInt(normalized.filter { $0 == "\n" }.count + 1))
        }
    }
    public static func droppedFileText(paths: [String]) -> String {
        guard !paths.isEmpty else { return "" }
        return paths.map(shellQuote).joined(separator: " ") + " "
    }
    private static func shellQuote(_ path: String) -> String {
        let safe = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "/_-.~"))
        if !path.isEmpty && path.unicodeScalars.allSatisfy(safe.contains) {
            return path
        }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    public func insertDroppedFileURLs(_ urls: [URL]) {
        pasteString(Self.droppedFileText(paths: urls.filter(\.isFileURL).map(\.path)))
    }
    @objc public func paste(_ sender: Any?) { pasteString(NSPasteboard.general.string(forType: .string) ?? "") }
    @objc public func copy(_ sender: Any?) { surface.copy(sender as Any) }
    public override func selectAll(_ sender: Any?) { surface.selectAll(sender) }
    @objc public func sendBytes(_ bytes: UnsafePointer<CChar>, length: Int) {
        _ = enqueueInputData(Data(bytes: bytes, count: length))
    }
    @objc public func sendUserBytes(_ bytes: UnsafePointer<CChar>, length: Int) {
        sendUserData(Data(bytes: bytes, count: length))
    }
    @discardableResult private func sendUserData(_ data: Data) -> Bool {
        guard inputEnabled, enqueueInputData(data) else { return false }
        scrollToBottom()
        userDidSendInput?()
        return true
    }
    @objc @discardableResult public func enqueueInputData(_ data: Data) -> Bool {
        precondition(Thread.isMainThread)
        if let inputHandler { return inputHandler(data) }
        guard pty >= 0, pendingInput.count - inputOffset + data.count <= 4 * 1_048_576 else { return false }
        if inputOffset > 0 { pendingInput.removeFirst(inputOffset); inputOffset = 0 }
        pendingInput.append(data)
        drainInput()
        return true
    }
    private func drainInput() {
        while inputOffset < pendingInput.count {
            let written = pendingInput.withUnsafeBytes { raw in
                Darwin.write(pty, raw.baseAddress!.advanced(by: inputOffset), raw.count - inputOffset)
            }
            if written > 0 { inputOffset += written; continue }
            if written < 0 && errno == EINTR { continue }
            if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                if writeSource == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: pty, queue: .main)
                    source.setEventHandler { [weak self] in self?.drainInput() }
                    writeSource = source
                    source.resume()
                }
                return
            }
            pendingInput.removeAll(); inputOffset = 0
            writeSource?.cancel(); writeSource = nil
            inputFailed?()
            return
        }
        pendingInput.removeAll(keepingCapacity: true); inputOffset = 0
        writeSource?.cancel(); writeSource = nil
    }

    public func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) { gridSizeChanged?() }
    public func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) { titleChanged?(title) }
    public func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
    public func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        guard inputEnabled else { return }
        _ = enqueueInputData(Data(data))
    }
    public func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
    public func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    public func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }
    public func bell(source: SwiftTerm.TerminalView) { NSSound.beep() }
    // Deliberately keep TerminalViewDelegate's deny-by-default OSC 52 clipboard
    // implementations. Terminal output must not read or overwrite the clipboard.
}
