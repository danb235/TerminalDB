import AppKit
import ServiceManagement
import Darwin

@objc(TDBPeerServices)
public final class TDBPeerServices: NSObject {
    private static var children: [Process] = []
    @objc public static func start() throws {
        if Bundle.main.bundlePath == "/Applications/TerminalDB.app" {
            try PeerPaths.prepare()
            for (socket, executable, plist) in [
                ("host", "TerminalDBSessionHost", "com.terminaldb.session-host.plist"),
                ("peer", "TerminalDBPeerAgent", "com.terminaldb.peer-agent.plist")
            ] {
                let service = SMAppService.agent(plistName: plist)
                if service.status == .enabled {
                    try repairStoppedService(service, socket: socket, executable: executable)
                }
                if service.status == .notRegistered || service.status == .notFound {
                    try service.register()
                }
                if service.status == .requiresApproval {
                    throw PeerFailure("Enable TerminalDB in System Settings → General → Login Items & Extensions, then reconnect.")
                }
                guard service.status == .enabled else {
                    throw PeerFailure("TerminalDB could not register its background services. Reinstall it in Applications, then reopen it.")
                }
            }
        } else {
            // Development/automated QA starts the same signed helpers without
            // registering a worktree path as a persistent login service.
            for (socket, argument) in [("host", "--session-host"), ("peer", "--peer-agent")] {
                if (try? PeerLocalConnection.connect(socket)) != nil { continue }
                guard let executable = Bundle.main.executableURL else { throw PeerFailure("The helper executable is missing.") }
                let process = Process()
                process.executableURL = executable
                process.arguments = [argument]
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                children.append(process)
            }
        }
    }
    private static func repairStoppedService(_ service: SMAppService, socket: String, executable: String) throws {
        let fd = Darwin.open(PeerPaths.file(socket + ".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw PeerFailure("TerminalDB could not check its background service. Check this user’s Application Support permissions.") }
        defer { Darwin.close(fd) }
        // A live host's lease protects its shells, even when its UI/IPC is slow.
        // Hold an unowned lease until unregister finishes so no new work can
        // start in the old registration during repair.
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return }
        defer { flock(fd, LOCK_UN) }
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/" + executable).path
        let capacity = max(1024, Int(proc_listallpids(nil, 0)) + 256)
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count >= 0 else { return }
        for pid in pids.prefix(min(Int(count), capacity)) where pid > 0 {
            var name = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pid, &name, UInt32(name.count)) > 0 && String(cString: name) == path {
                return // Includes a helper waiting on its macOS Keychain prompt.
            }
        }
        // macOS can retain an enabled registration pointing at a replaced
        // bundle. Refresh only a stopped service; never stop a running host.
        try service.unregister()
        flock(fd, LOCK_UN)
        try service.register()
    }
    @objc public static func openBackgroundSettings() { SMAppService.openSystemSettingsLoginItems() }
}

@objc(TDBPeerPanel)
public final class TDBPeerPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    @objc public let view = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 720))
    @objc public private(set) var peerInventory: NSDictionary = [:]
    @objc public var changed: (() -> Void)?
    private let client = TDBSessionClient()
    private let status = NSTextField(wrappingLabelWithString: "Connecting to the workstation service…")
    private let fingerprint = NSTextField(wrappingLabelWithString: "")
    private let table = NSTableView()
    private let address = NSTextField()
    private var rows: [[String: Any]] = []
    private var timer: Timer?

    public override init() {
        super.init()
        client.agentManagement = true
        status.frame = NSRect(x: 20, y: 652, width: 780, height: 48)
        fingerprint.frame = NSRect(x: 20, y: 590, width: 780, height: 58)
        fingerprint.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        fingerprint.isSelectable = true
        view.addSubview(status); view.addSubview(fingerprint)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("peer"))
        column.title = "Workstations and pairing requests"; column.width = 760
        table.addTableColumn(column); table.headerView = nil
        table.dataSource = self; table.delegate = self
        table.rowHeight = 48
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 322, width: 780, height: 254))
        scroll.hasVerticalScroller = true; scroll.documentView = table
        view.addSubview(scroll)
        addButton("Open Pairing for 3 Minutes", x: 20, y: 282, width: 218, action: #selector(openPairing))
        addButton("Pair Nearby Mac", x: 246, y: 282, width: 155, action: #selector(pair))
        addButton("Verify & Approve", x: 409, y: 282, width: 155, action: #selector(approve))
        addButton("Remove Pairing", x: 572, y: 282, width: 150, action: #selector(remove))
        address.frame = NSRect(x: 20, y: 238, width: 548, height: 26)
        address.placeholderString = "Internal address:port, workstation.local, or [fd00::10]:49377"
        address.setAccessibilityLabel("Workstation LAN or VPN address")
        view.addSubview(address)
        addButton("Save Address", x: 580, y: 236, width: 142, action: #selector(saveAddress))
        addButton("Test Connection", x: 20, y: 188, width: 190, action: #selector(testAddress))
        addButton("Retry Pending Removals", x: 230, y: 188, width: 235, action: #selector(retryRemovals))
        let help = NSTextField(wrappingLabelWithString:
            "Pair on the same LAN and compare both complete device fingerprints. When away, connect your VPN first. Bonjour discovery may not cross a VPN: select the paired Mac and save its internal IP address or internal DNS name. No router port forwarding, public endpoint or relay is used. The execution Mac must remain awake and logged in; after your viewing laptop wakes, the same session reconnects.")
        help.frame = NSRect(x: 20, y: 40, width: 780, height: 122)
        help.font = .systemFont(ofSize: 11)
        view.addSubview(help)
        client.eventHandler = { [weak self] event in
            if event["type"] as? String == "peers.state" { self?.apply(event) }
        }
        client.connect { [weak self] _ in self?.refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    private func addButton(_ title: String, x: CGFloat, y: CGFloat, width: CGFloat, action: Selector) {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.frame = NSRect(x: x, y: y, width: width, height: 30)
        view.addSubview(button)
    }
    @objc public func refresh() {
        guard client.connected else {
            if let detail = try? String(contentsOf: PeerPaths.file("startup-error.txt"), encoding: .utf8) { status.stringValue = detail }
            return
        }
        client.request("peers.state", payload: [:]) { [weak self] result in self?.apply(result) }
    }
    private func apply(_ result: NSDictionary) {
        guard result["error"] == nil else { status.stringValue = result["error"] as? String ?? "Unavailable"; return }
        if let test = result["testResult"] as? String {
            let alert = NSAlert(); alert.messageText = "Workstation connection"; alert.informativeText = test; alert.runModal(); return
        }
        peerInventory = result
        let open = result["pairingOpen"] as? Bool ?? false
        status.stringValue = "\(result["status"] as? String ?? "Ready") · \(open ? "Pairing is open" : "Pairing is closed")\n\(result["detail"] as? String ?? "")"
        if let pending = result["pendingRemovals"] as? [String], !pending.isEmpty {
            status.stringValue += "\nRemoval pending on: " + pending.joined(separator: ", ")
        }
        fingerprint.stringValue = "THIS MAC’S DEVICE FINGERPRINT (\(result["hardwareBacked"] as? Bool == true ? "Secure Enclave" : "software Keychain"))\n" + (result["fingerprint"] as? String ?? "")
        // Discovery and pending approvals can reorder while the panel is open.
        // Preserve the selected device, never the old numeric row position.
        func identity(_ row: [String: Any]) -> String {
            (row["kind"] as? String ?? "") + ":" + (row["id"] as? String ?? row["service"] as? String ?? "")
        }
        let selection = selected.map(identity)
        rows = []
        for (key, kind) in [("candidates", "candidate"), ("peers", "peer"), ("nearby", "nearby")] {
            for var row in result[key] as? [[String: Any]] ?? [] { row["kind"] = kind; rows.append(row) }
        }
        table.reloadData()
        if let selection, let index = rows.firstIndex(where: { identity($0) == selection }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else { table.deselectAll(nil) }
        updateAddressField()
        changed?()
    }
    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let item = rows[row]
        let kind = item["kind"] as? String ?? ""
        let title = item["name"] as? String ?? item["service"] as? String ?? "Mac"
        let detail: String
        if kind == "candidate" { detail = "VERIFY: " + (item["fingerprint"] as? String ?? "") }
        else if kind == "peer" { detail = "Paired · " + ((item["endpoints"] as? [[String: String]] ?? []).map { $0["address"] ?? "" }.joined(separator: ", ")) }
        else { detail = "Nearby · " + (item["address"] as? String ?? "") }
        let label = NSTextField(wrappingLabelWithString: title + "\n" + detail)
        label.font = .systemFont(ofSize: 11); label.isSelectable = false
        return label
    }
    private var selected: [String: Any]? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }
    private func perform(_ operation: String, payload: [String: Any]) {
        client.request(operation, payload: payload as NSDictionary) { [weak self] result in
            if let error = result["error"] as? String {
                let alert = NSAlert(); alert.messageText = "Workstation connection"; alert.informativeText = error; alert.runModal()
            } else { self?.apply(result) }
        }
    }
    @objc private func openPairing() { perform("peers.pairing.open", payload: [:]) }
    @objc private func pair() {
        guard let selected, let service = selected["service"] as? String else {
            status.stringValue = "Select a nearby Mac first, and open pairing on both Macs."; return
        }
        perform("peers.pair", payload: ["service": service])
    }
    @objc private func approve() {
        guard let selected, selected["kind"] as? String == "candidate",
              let id = selected["id"] as? String, let peerFingerprint = selected["fingerprint"] as? String else { return }
        let alert = NSAlert()
        alert.messageText = "Verify both device fingerprints"
        alert.informativeText = "Compare the complete fingerprints with the ones displayed on the other Mac. Approve on both Macs only if they match.\n\nThis Mac:\n\(peerInventory["fingerprint"] as? String ?? "")\n\nOther Mac:\n\(peerFingerprint)"
        alert.addButton(withTitle: "Fingerprints Match"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform("peers.approve", payload: ["candidate": id, "fingerprint": peerFingerprint])
    }
    @objc private func remove() {
        guard let selected, selected["kind"] as? String == "peer", let id = selected["id"] as? String else { return }
        let alert = NSAlert(); alert.messageText = "Remove this pairing?"
        alert.informativeText = "Access to this Mac stops immediately. You can also apply the removal separately on your other paired Macs. Unreachable Macs remain pending until you retry. Remove this Mac from the removed workstation too."
        alert.addButton(withTitle: "Remove From My Macs"); alert.addButton(withTitle: "Remove Here Only"); alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn || response == .alertSecondButtonReturn {
            perform("peers.remove", payload: ["peerId": id, "otherMacs": response == .alertFirstButtonReturn])
        }
    }
    @objc private func saveAddress() {
        guard let selected, selected["kind"] as? String == "peer", let id = selected["id"] as? String else {
            status.stringValue = "Select a paired workstation before saving its LAN or VPN address."; return
        }
        perform("peers.endpoint", payload: ["peerId": id, "address": address.stringValue])
    }
    @objc private func retryRemovals() { perform("peers.retryRemovals", payload: [:]) }
    @objc private func testAddress() {
        guard let selected, selected["kind"] as? String == "peer", let id = selected["id"] as? String else {
            status.stringValue = "Select a paired workstation to test its saved internal address."; return
        }
        perform("peers.testAddress", payload: ["peerId": id])
    }
    public func tableViewSelectionDidChange(_ notification: Notification) { updateAddressField() }
    private func updateAddressField() {
        guard address.currentEditor() == nil else { return }
        let endpoints = selected?["endpoints"] as? [[String: String]] ?? []
        address.stringValue = endpoints.first(where: { $0["scope"] == "manual" })?["address"] ?? ""
    }
}
