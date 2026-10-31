import AppKit

// Labels are presentation only; authorization always uses the pinned key.
@objc(TDBWorkstationPresentation)
public final class TDBWorkstationPresentation: NSObject {
    @objc public static func displayName(_ value: String) -> String {
        PeerProtocol.displayName(value)
    }
    @objc(tabTitleForWorkstation:session:)
    public static func tabTitle(workstation: String, session: String) -> String {
        displayName(workstation) + " · " + displayName(session)
    }
}

@objc(TDBSessionBrowser)
public final class TDBSessionBrowser: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private var alert: NSAlert?
    private var client: TDBSessionClient?
    private let macs = NSPopUpButton()
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var choices: [(id: String, name: String)] = []
    private var rows: [[String: Any]] = []
    private var generation = 0
    private var completion: ((String, String, String) -> Void)?

    @objc(showInWindow:peers:workstation:completion:)
    public func show(in window: NSWindow, peers: NSArray, workstation: String,
                     completion: @escaping (String, String, String) -> Void) {
        self.completion = completion
        choices = [("", "This Mac")] + (peers as? [[String: Any]] ?? []).compactMap {
            guard let id = $0["id"] as? String, let name = $0["name"] as? String else { return nil }
            return (id, TDBWorkstationPresentation.displayName(name))
        }
        let alert = NSAlert(); self.alert = alert
        alert.messageText = "Resume a session"
        alert.informativeText = "Choose the Mac where the session is running. Opening a view keeps its shell and work in place."
        alert.addButton(withTitle: "Open Session"); alert.addButton(withTitle: "Cancel")
        alert.buttons[0].isEnabled = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 290))
        let label = NSTextField(labelWithString: "Mac")
        label.frame = NSRect(x: 0, y: 256, width: 50, height: 24); content.addSubview(label)
        macs.frame = NSRect(x: 50, y: 254, width: 470, height: 28)
        macs.setAccessibilityLabel("Session workstation")
        macs.addItems(withTitles: choices.map(\.name))
        macs.selectItem(at: choices.firstIndex(where: { $0.id == workstation }) ?? 0)
        macs.target = self; macs.action = #selector(loadSessions)
        content.addSubview(macs)
        let column = NSTableColumn(identifier: .init("session")); column.width = 490
        table.addTableColumn(column); table.headerView = nil; table.rowHeight = 52
        table.dataSource = self; table.delegate = self
        table.target = self; table.doubleAction = #selector(openSelected)
        table.setAccessibilityLabel("Running terminal sessions")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 40, width: 520, height: 200))
        scroll.hasVerticalScroller = true; scroll.documentView = table
        content.addSubview(scroll)
        status.frame = NSRect(x: 0, y: 0, width: 410, height: 34)
        status.font = .systemFont(ofSize: 11); content.addSubview(status)
        let retry = NSButton(title: "Refresh", target: self, action: #selector(loadSessions))
        retry.frame = NSRect(x: 424, y: 3, width: 96, height: 28); content.addSubview(retry)
        alert.accessoryView = content
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            let choice = self.choices[self.macs.indexOfSelectedItem]
            let session = self.rows.indices.contains(self.table.selectedRow)
                ? self.rows[self.table.selectedRow]["sessionId"] as? String : nil
            self.client?.close(); self.client = nil; self.alert = nil
            let callback = self.completion; self.completion = nil
            if response == .alertFirstButtonReturn, let session { callback?(choice.id, session, choice.name) }
        }
        loadSessions()
    }

    @objc private func loadSessions() {
        generation += 1; let current = generation
        client?.close(); rows = []; table.reloadData(); alert?.buttons[0].isEnabled = false
        let choice = choices[macs.indexOfSelectedItem]
        status.stringValue = "Connecting to \(choice.name)…"
        let client = TDBSessionClient(); self.client = client; client.workstationID = choice.id
        client.eventHandler = { [weak self] event in
            guard let self, self.generation == current else { return }
            if ["connection-error", "disconnected"].contains(event["type"] as? String ?? "") {
                self.status.stringValue = choice.id.isEmpty
                    ? "The local session service is starting. Refresh to try again."
                    : "Waiting for \(choice.name). Check that it is awake; connect your VPN when away."
            }
        }
        client.connect { [weak self] _ in
            guard let self, self.generation == current else { return }
            client.request("session.list", payload: [:]) { [weak self] result in
                guard let self, self.generation == current else { return }
                self.rows = result["sessions"] as? [[String: Any]] ?? []
                self.table.reloadData()
                if self.rows.count == 1 { self.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
                self.status.stringValue = result["error"] as? String
                    ?? (self.rows.isEmpty ? "No running sessions on \(choice.name). Start one from the Workstations menu." : "Sessions stay running when their tabs or windows close.")
                self.alert?.buttons[0].isEnabled = self.table.selectedRow >= 0
            }
        }
    }
    @objc private func openSelected() {
        guard table.selectedRow >= 0, let alert else { return }
        alert.window.sheetParent?.endSheet(alert.window, returnCode: .alertFirstButtonReturn)
    }
    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    public func tableViewSelectionDidChange(_ notification: Notification) { alert?.buttons[0].isEnabled = table.selectedRow >= 0 }
    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let item = rows[row]
        let title = TDBWorkstationPresentation.displayName(item["title"] as? String ?? "Terminal")
        let directory = item["directory"] as? String ?? ""
        let label = NSTextField(wrappingLabelWithString: title + (item["busy"] as? Bool == true ? " · Running" : "") + "\n" + directory)
        label.font = .systemFont(ofSize: 12); label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }
    @objc public func cancel() {
        if let alert { alert.window.sheetParent?.endSheet(alert.window, returnCode: .alertSecondButtonReturn) }
        client?.close(); client = nil
    }
}
