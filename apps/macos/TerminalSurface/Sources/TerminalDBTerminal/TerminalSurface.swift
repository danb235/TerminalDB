import AppKit
import SwiftTerm

// The emulator, renderer, selection and scrollback belong to SwiftTerm. This
// adapter owns only TerminalDB's PTY transport and product integration.
private final class SurfaceView: SwiftTerm.TerminalView {
    weak var owner: TDBTerminalSurface?
    override func insertText(_ string: Any, replacementRange: NSRange) {
        // Cocoa input methods may commit attributed text; SwiftTerm's public
        // insertion path expects a string. Keep composition in the native view.
        super.insertText((string as? NSAttributedString)?.string ?? string,
                         replacementRange: replacementRange)
    }
    override func paste(_ sender: Any) {
        owner?.pasteString(NSPasteboard.general.string(forType: .string) ?? "")
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
    @objc public var inputEnabled = true
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
        addSubview(surface)
        layoutTerminalSurface()
        surface.terminal.registerOscHandler(code: 633) { [weak self] bytes in
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
        set { surface.nativeForegroundColor = newValue }
    }
    @objc public var backgroundColor: NSColor {
        get { surface.nativeBackgroundColor }
        set {
            surface.nativeBackgroundColor = newValue
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
        surface.installColors(colors.map { color in
            let rgb = color.usingColorSpace(.deviceRGB) ?? .white
            return Color(red: UInt16(rgb.redComponent * 65535),
                         green: UInt16(rgb.greenComponent * 65535),
                         blue: UInt16(rgb.blueComponent * 65535))
        })
    }
    @objc public var terminalRows: Int { surface.terminal.rows }
    @objc public var terminalColumns: Int { surface.terminal.cols }
    @objc public var bracketedPaste: Bool { surface.terminal.bracketedPasteMode }
    @objc public var applicationCursorKeys: Bool { surface.terminal.applicationCursor }
    @objc public var alternateScreenActive: Bool { surface.terminal.isCurrentBufferAlternate }
    @objc public var selectionText: String { surface.getSelection() ?? "" }
    @objc public var hasKeyboardFocus: Bool { window?.firstResponder === surface }
    @objc public var string: String {
        surface.terminal.getText(start: Position(col: 0, row: 0),
            end: Position(col: terminalColumns, row: lineCount - 1))
    }
    private var lineCount: Int {
        // BufferLine identities expose the complete bounded buffer without
        // depending on SwiftTerm's internal yBase or circular-array storage.
        var low = 0, high = 10000 + terminalRows + 1
        let trimmed = surface.terminal.buffer.totalLinesTrimmed
        while low < high {
            let mid = (low + high) / 2
            if surface.terminal.getScrollInvariantLine(row: trimmed + mid) != nil { low = mid + 1 }
            else { high = mid }
        }
        return max(1, low)
    }
    @objc public func feedData(_ data: Data) {
        precondition(Thread.isMainThread)
        surface.feed(byteArray: Array(data)[...])
    }
    @objc public func feedText(_ text: String) { feedData(Data(text.utf8)) }
    @objc public func resizeGrid(columns: Int, rows: Int) {
        // TerminalView.resize performs a soft reset: that would lose bracketed
        // paste and application cursor modes on every remote resize.
        surface.terminal.resize(cols: max(2, columns), rows: max(2, rows))
        surface.sizeChanged(source: surface.terminal)
        surface.needsDisplay = true
    }
    @objc public func scrollToBottom() { surface.scroll(toPosition: 1) }
    @objc public var isAtBottom: Bool { !surface.canScroll || surface.scrollPosition >= 0.999 }
    @objc public func visibleText() -> String {
        let top = surface.terminal.getTopVisibleRow()
        return surface.terminal.getText(start: Position(col: 0, row: top),
            end: Position(col: terminalColumns, row: top + terminalRows - 1))
    }
    @objc public func ansiSnapshot() -> String {
        TerminalSnapshot.encode(surface.terminal, cursorVisible: terminalCursorVisible, lineCount: lineCount)
    }
    @objc public func beginCommandCapture() {
        let term = surface.terminal!
        let row = max(0, lineCount - term.rows) + term.buffer.y
        commandStartLine = term.bufferLine(atRow: row)
        commandStartRow = row
        commandStartTrimmed = term.buffer.totalLinesTrimmed
        commandStartColumn = term.buffer.x
    }
    @objc public func endCommandCapture() -> String {
        let term = surface.terminal!
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
        guard pty >= 0 else { return false }
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
