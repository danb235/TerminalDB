import AppKit
import ServiceManagement

@objc(TDBPeerServices)
public final class TDBPeerServices: NSObject {
    private static var children: [Process] = []
    @objc public static func start() throws {
        if Bundle.main.bundlePath == "/Applications/TerminalDB.app" {
            for plist in ["com.terminaldb.session-host.plist", "com.terminaldb.peer-agent.plist"] {
                let service = SMAppService.agent(plistName: plist)
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
    @objc public static func openBackgroundSettings() { SMAppService.openSystemSettingsLoginItems() }
}

@objc(TDBPeerPanel)
public final class TDBPeerPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    @objc public let view = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 720))
    @objc public private(set) var peerInventory: NSDictionary = [:]
    @objc public var changed: (() -> Void)?
    private let client = TDBSessionClient()
    private let status = NSTextField(wrappingLabelWithString: "Connecting to the peer service…")
    private let fingerprint = NSTextField(wrappingLabelWithString: "")
    private let table = NSTableView()
    private let address = NSTextField()
    private let publicAddress = NSTextField()
    private let forwarding = NSButton(checkboxWithTitle: "Allow this Mac to forward encrypted connections for paired Macs", target: nil, action: nil)
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
        address.placeholderString = "Selected Mac's public address:port (IPv6: [address]:port)"
        address.setAccessibilityLabel("Workstation internet address")
        view.addSubview(address)
        addButton("Save Address", x: 580, y: 236, width: 142, action: #selector(saveAddress))
        forwarding.frame = NSRect(x: 20, y: 199, width: 780, height: 26)
        forwarding.target = self; forwarding.action = #selector(setForwarding)
        view.addSubview(forwarding)
        publicAddress.frame = NSRect(x: 20, y: 150, width: 548, height: 26)
        publicAddress.placeholderString = "This Mac’s public address:port (optional)"
        publicAddress.setAccessibilityLabel("This Mac internet address")
        view.addSubview(publicAddress)
        addButton("Save This Address", x: 580, y: 148, width: 180, action: #selector(savePublicAddress))
        addButton("Test From Selected Mac", x: 20, y: 108, width: 235, action: #selector(testEndpoint))
        addButton("Retry Pending Removals", x: 275, y: 108, width: 235, action: #selector(retryRemovals))
        let help = NSTextField(wrappingLabelWithString:
            "Pair on the same LAN and compare the full device fingerprints on both Macs. For access away from home, forward TCP port 49377 to a paired Mac, or allow it through your IPv6 firewall. Test from another network. If its public address changes and no saved path works, update that address. No public discovery or relay service is used.")
        help.frame = NSRect(x: 20, y: 14, width: 780, height: 74)
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
            let alert = NSAlert(); alert.messageText = "Internet reachability"; alert.informativeText = test; alert.runModal(); return
        }
        peerInventory = result
        if publicAddress.currentEditor() == nil { publicAddress.stringValue = result["publicAddress"] as? String ?? "" }
        let open = result["pairingOpen"] as? Bool ?? false
        status.stringValue = "\(result["status"] as? String ?? "Ready") · \(open ? "Pairing is open" : "Pairing is closed")\n\(result["detail"] as? String ?? "")"
        if let pending = result["pendingRemovals"] as? [String], !pending.isEmpty {
            status.stringValue += "\nRemoval pending on: " + pending.joined(separator: ", ")
        }
        fingerprint.stringValue = "THIS MAC’S DEVICE FINGERPRINT (\(result["hardwareBacked"] as? Bool == true ? "Secure Enclave" : "software Keychain"))\n" + (result["fingerprint"] as? String ?? "")
        forwarding.state = result["forwarding"] as? Bool == true ? .on : .off
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
            status.stringValue = "Select a paired workstation before saving its internet address."; return
        }
        perform("peers.endpoint", payload: ["peerId": id, "address": address.stringValue])
    }
    @objc private func retryRemovals() { perform("peers.retryRemovals", payload: [:]) }
    @objc private func savePublicAddress() { perform("peers.publicEndpoint", payload: ["address": publicAddress.stringValue]) }
    @objc private func testEndpoint() {
        guard let selected, selected["kind"] as? String == "peer", let id = selected["id"] as? String else {
            status.stringValue = "Select a paired Mac on another network to test this Mac’s saved public address."; return
        }
        perform("peers.testEndpoint", payload: ["peerId": id])
    }
    @objc private func setForwarding() { perform("peers.forwarding", payload: ["enabled": forwarding.state == .on]) }
}
