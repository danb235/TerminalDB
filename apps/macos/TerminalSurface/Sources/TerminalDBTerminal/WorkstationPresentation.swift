import AppKit

// Labels are presentation only; authorization always uses the pinned key.
@objc(TDBWorkstationPresentation)
public final class TDBWorkstationPresentation: NSObject {
    @objc public static func displayName(_ value: String) -> String { PeerProtocol.displayName(value) }
    @objc(tabTitleForWorkstation:session:)
    public static func tabTitle(workstation: String, session: String) -> String {
        displayName(workstation) + " · " + displayName(session)
    }
}

struct WorkstationSessionRow: Equatable {
    enum Kind { case heading, newTerminal, session, status }
    var kind: Kind
    var workstation: String
    var macName: String
    var session = ""
    var title: String
    var detail = ""
    var identity: String { workstation + ":" + String(describing: kind) + ":" + session }
    var selectable: Bool { kind == .newTerminal || kind == .session }
}

enum WorkstationSessionPresentation {
    static func selection(in rows: [WorkstationSessionRow], previous: String?, preferredWorkstation: String) -> Int? {
        if let previous { return rows.firstIndex { $0.identity == previous && $0.selectable } }
        return rows.firstIndex { $0.workstation == preferredWorkstation && $0.kind == .newTerminal } ?? rows.firstIndex(where: \.selectable)
    }
    static func rows(macs: [(id: String, name: String)], sessions: [String: [[String: Any]]], statuses: [String: String], filter: String) -> [WorkstationSessionRow] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows: [WorkstationSessionRow] = []
        for mac in macs {
            let matchesMac = query.isEmpty || mac.name.localizedCaseInsensitiveContains(query)
            let items = (sessions[mac.id] ?? []).prefix(256).filter { item in
                matchesMac || (item["title"] as? String ?? "").localizedCaseInsensitiveContains(query)
                    || (item["directory"] as? String ?? "").localizedCaseInsensitiveContains(query)
            }
            guard matchesMac || !items.isEmpty else { continue }
            rows.append(.init(kind: .heading, workstation: mac.id, macName: mac.name, title: mac.name))
            rows.append(.init(kind: .newTerminal, workstation: mac.id, macName: mac.name, title: "New Terminal", detail: "Start on \(mac.name)"))
            if let status = statuses[mac.id], !status.isEmpty {
                rows.append(.init(kind: .status, workstation: mac.id, macName: mac.name, title: status))
            }
            for item in items {
                guard let id = item["sessionId"] as? String, !id.isEmpty else { continue }
                let title = TDBWorkstationPresentation.displayName(item["title"] as? String ?? "Terminal")
                let directory = item["directory"] as? String ?? ""
                let detail = (item["busy"] as? Bool == true ? "Running" : "Existing session") + (directory.isEmpty ? "" : " · " + directory)
                rows.append(.init(kind: .session, workstation: mac.id, macName: mac.name, session: id, title: title, detail: detail))
            }
        }
        return rows
    }
}

@objc(TDBSessionBrowser)
public final class TDBSessionBrowser: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private var panel: NSPanel?
    private let table = NSTableView()
    private let search = NSSearchField()
    private let open = NSButton()
    private var macs: [(id: String, name: String)] = []
    private var sessions: [String: [[String: Any]]] = [:]
    private var statuses: [String: String] = [:]
    private var rows: [WorkstationSessionRow] = []
    private var clients: [String: TDBSessionClient] = [:]
    private var loading = Set<String>()
    private var pending: [(id: String, name: String)] = []
    private var generation = 0
    private var preferredWorkstation = ""
    private var previousFilter = ""
    private var completion: ((String, String, String) -> Void)?

    // An empty session identity requests a new terminal. Existing session
    // identities always remain attached to their original workstation.
    @objc(showInWindow:peers:workstation:completion:)
    public func show(in window: NSWindow, peers: NSArray, workstation: String,
                     completion: @escaping (String, String, String) -> Void) {
        cancel()
        self.completion = completion; preferredWorkstation = workstation
        macs = [("", "This Mac")] + (peers as? [[String: Any]] ?? []).prefix(128).compactMap {
            guard let id = $0["id"] as? String, !id.isEmpty, let name = $0["name"] as? String else { return nil }
            return (id, TDBWorkstationPresentation.displayName(name))
        }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Macs & Sessions"; self.panel = panel
        let title = NSTextField(labelWithString: "Open a Terminal")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString: "Start a new terminal or open an existing session where it is running.")
        subtitle.font = .systemFont(ofSize: 13); subtitle.textColor = .secondaryLabelColor
        search.placeholderString = "Find a Mac or session"; search.setAccessibilityLabel("Find a Mac or session")
        search.delegate = self; search.stringValue = ""
        if table.tableColumns.isEmpty {
            let column = NSTableColumn(identifier: .init("session")); column.width = 540
            table.addTableColumn(column); table.headerView = nil; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            table.dataSource = self; table.delegate = self; table.target = self; table.action = #selector(clickSessionRow)
            table.intercellSpacing = NSSize(width: 0, height: 2)
            table.setAccessibilityLabel("Macs and terminal sessions")
        }
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = table; scroll.borderType = .noBorder
        scroll.heightAnchor.constraint(equalToConstant: 292).isActive = true
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel)); cancel.keyEquivalent = "\u{1b}"
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(loadSessions))
        open.title = "New Terminal"; open.target = self; open.action = #selector(openSelected); open.keyEquivalent = "\r"
        let footer = NSStackView(views: [cancel, refresh, NSView(), open]); footer.orientation = .horizontal; footer.spacing = 10
        let stack = NSStackView(views: [title, subtitle, search, scroll, footer])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(stack)
        for item in stack.arrangedSubviews { item.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 24), stack.bottomAnchor.constraint(lessThanOrEqualTo: panel.contentView!.bottomAnchor, constant: -24)])
        window.beginSheet(panel)
        loadSessions(); panel.makeFirstResponder(search)
    }

    @objc private func loadSessions() {
        generation += 1
        for client in clients.values { client.close() }; clients.removeAll(); loading.removeAll()
        pending = macs.sorted { left, right in
            let a = left.id == preferredWorkstation ? 0 : left.id.isEmpty ? 1 : 2
            let b = right.id == preferredWorkstation ? 0 : right.id.isEmpty ? 1 : 2
            return a == b ? left.name.localizedStandardCompare(right.name) == .orderedAscending : a < b
        }
        statuses = Dictionary(uniqueKeysWithValues: macs.map { ($0.id, "Looking for existing sessions…") })
        renderRows(); startNextQueries()
    }
    private func startNextQueries() {
        guard panel != nil else { return }
        while loading.count < 4, !pending.isEmpty {
            let mac = pending.removeFirst(), current = generation
            let client = TDBSessionClient(); clients[mac.id] = client; loading.insert(mac.id); client.workstationID = mac.id
            client.eventHandler = { [weak self] event in
                guard let self, self.generation == current, self.loading.contains(mac.id) else { return }
                if ["connection-error", "disconnected"].contains(event["type"] as? String ?? "") {
                    self.finishQuery(mac.id, sessions: nil, error: mac.id.isEmpty ? "Local session service is starting." : "Unavailable · Check LAN, VPN and power.")
                }
            }
            client.connect { [weak self, weak client] _ in
                guard let self, let client, self.generation == current, self.loading.contains(mac.id) else { return }
                client.request("session.list", payload: [:]) { [weak self] result in
                    guard let self, self.generation == current, self.loading.contains(mac.id) else { return }
                    self.finishQuery(mac.id, sessions: result["sessions"] as? [[String: Any]], error: result["error"] as? String)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                guard let self, self.generation == current, self.loading.contains(mac.id) else { return }
                self.finishQuery(mac.id, sessions: nil, error: mac.id.isEmpty ? "Local session service is starting." : "Unavailable · Check LAN, VPN and power.")
            }
        }
    }
    private func finishQuery(_ id: String, sessions: [[String: Any]]?, error: String?) {
        loading.remove(id)
        let client = clients.removeValue(forKey: id); client?.close()
        if let sessions { self.sessions[id] = Array(sessions.prefix(256)) }
        statuses[id] = error ?? ""
        renderRows(); startNextQueries()
    }
    private func renderRows() {
        let selected = previousFilter == search.stringValue && rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].identity : nil
        previousFilter = search.stringValue
        var next = WorkstationSessionPresentation.rows(macs: macs, sessions: sessions, statuses: statuses, filter: search.stringValue)
        if next.isEmpty { next = [.init(kind: .status, workstation: "", macName: "", title: "No matching Macs or sessions.")] }
        guard next != rows else { return }
        rows = next; table.reloadData()
        if let index = WorkstationSessionPresentation.selection(in: rows, previous: selected, preferredWorkstation: preferredWorkstation) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else { table.deselectAll(nil) }
        updateOpenButton()
    }
    public func controlTextDidChange(_ obj: Notification) { renderRows() }
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { openSelected(); return true }
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            panel?.makeFirstResponder(table)
            if table.selectedRow < 0, let index = rows.firstIndex(where: \.selectable) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
            return true
        }
        return false
    }
    private func updateOpenButton() {
        let selected = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil
        open.isEnabled = selected?.selectable == true
        open.title = selected?.kind == .session ? "Open Session" : "New Terminal"
    }
    @objc private func openSelected() {
        guard rows.indices.contains(table.selectedRow), rows[table.selectedRow].selectable else { return }
        let row = rows[table.selectedRow], callback = completion
        cancel(); callback?(row.workstation, row.session, row.macName)
    }
    @objc private func clickSessionRow() {
        guard rows.indices.contains(table.clickedRow), rows[table.clickedRow].selectable, table.clickedRow == table.selectedRow else { return }
        openSelected()
    }
    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    public func tableViewSelectionDidChange(_ notification: Notification) { updateOpenButton() }
    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows.indices.contains(row) && rows[row].selectable }
    public func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { rows.indices.contains(row) && rows[row].kind == .heading }
    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return 46 }; return rows[row].kind == .heading || rows[row].kind == .status ? 27 : 48
    }
    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }; let item = rows[row]
        let title = NSTextField(labelWithString: item.title)
        title.font = .systemFont(ofSize: item.kind == .status ? 12 : 13, weight: item.kind == .heading ? .semibold : .regular)
        title.lineBreakMode = .byTruncatingMiddle; title.textColor = item.kind == .status ? .secondaryLabelColor : .labelColor
        let labels = NSStackView(views: [title]); labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 2
        title.widthAnchor.constraint(lessThanOrEqualTo: labels.widthAnchor).isActive = true
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if !item.detail.isEmpty {
            let detail = NSTextField(labelWithString: item.detail); detail.font = .systemFont(ofSize: 12); detail.textColor = .secondaryLabelColor; detail.lineBreakMode = .byTruncatingMiddle
            labels.addArrangedSubview(detail)
            detail.widthAnchor.constraint(lessThanOrEqualTo: labels.widthAnchor).isActive = true
            detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let content: NSStackView
        if item.selectable {
            let icon = NSImageView(image: NSImage(systemSymbolName: item.kind == .newTerminal ? "plus" : "terminal", accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = .secondaryLabelColor; icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
            content = NSStackView(views: [icon, labels]); content.orientation = .horizontal; content.alignment = .centerY; content.spacing = 8
        } else { content = labels }
        let cell = NSTableCellView(); content.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8), content.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), content.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    @objc public func cancel() {
        generation += 1; let panel = self.panel; self.panel = nil; completion = nil
        for client in clients.values { client.close() }; clients.removeAll(); loading.removeAll(); pending.removeAll()
        if let panel { panel.sheetParent?.endSheet(panel); panel.orderOut(nil) }
    }
}
