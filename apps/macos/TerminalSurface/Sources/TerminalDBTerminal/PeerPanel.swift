import AppKit
import ServiceManagement
import Darwin

@objc(TDBWorkspaceReferences)
public final class TDBWorkspaceReferences: NSObject {
    // Older workspaces used an empty workstation for the collection's host.
    // New ones store the pinned device identity, including for This Mac.
    @objc(resolveWorkstation:owner:localDevice:)
    public static func resolveWorkstation(_ saved: String, owner: String, localDevice: String) -> String {
        let identity = saved.isEmpty ? owner : saved
        return !localDevice.isEmpty && identity == localDevice ? "" : identity
    }
}

@objc(TDBPeerServices)
public final class TDBPeerServices: NSObject {
    private static var children: [Process] = []
    @objc(startWithCompletion:)
    public static func start(completion: @escaping (NSError?) -> Void) {
        Task { @MainActor in
            do { try await startServices(); completion(nil) }
            catch { completion(error as NSError) }
        }
    }
    @MainActor private static func startServices() async throws {
        if Bundle.main.bundlePath == "/Applications/TerminalDB.app" {
            try PeerPaths.prepare()
            for (socket, executable, plist) in [
                ("host", "TerminalDBSessionHost", "com.terminaldb.session-host.plist"),
                ("peer", "TerminalDBPeerAgent", "com.terminaldb.peer-agent.plist")
            ] {
                let service = SMAppService.agent(plistName: plist)
                if service.status == .enabled {
                    try await repairStoppedService(service, socket: socket, executable: executable)
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
            for (socket, executable) in [("host", "TerminalDBSessionHost"), ("peer", "TerminalDBPeerAgent")] {
                if (try? PeerLocalConnection.connect(socket)) != nil { continue }
                let process = Process()
                process.executableURL = helperURL(executable)
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                children.append(process)
            }
        }
    }
    @MainActor private static func repairStoppedService(_ service: SMAppService, socket: String, executable: String) async throws {
        let fd = Darwin.open(PeerPaths.file(socket + ".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw PeerFailure("TerminalDB could not check its background service. Check this user’s Application Support permissions.") }
        defer { Darwin.close(fd) }
        // A live host's lease protects its shells, even when its UI/IPC is slow.
        // Hold an unowned lease until unregister finishes so no new work can
        // start in the old registration during repair.
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return }
        defer { flock(fd, LOCK_UN) }
        let path = helperURL(executable).path
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
        // The synchronous API returns before launchd/BTM has retired the old
        // process and signing constraint. Only the async completion makes it
        // safe to register the new executable's signature after an update.
        try await service.unregister()
        flock(fd, LOCK_UN)
        try service.register()
    }
    private static func helperURL(_ executable: String) -> URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(executable).app/Contents/MacOS/\(executable)")
    }
    @objc public static func openBackgroundSettings() { SMAppService.openSystemSettingsLoginItems() }
}

@objc(TDBPeerPanel)
public final class TDBPeerPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    @objc public let view = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 500))
    @objc public private(set) var peerInventory: NSDictionary = [:]
    @objc public var changed: (() -> Void)?
    @objc public var openTerminalHandler: ((String, String) -> Void)?
    @objc public var openSessionsHandler: ((String) -> Void)?
    private let client = TDBSessionClient()
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "Preparing connections to your other Macs…")
    private var rows: [[String: Any]] = []
    private var timer: Timer?
    private var actions: [NSButton] = []
    private var feedback = ""
    private var feedbackUntil = 0.0
    private var preferredSelection: String?
    private var pairPanel: NSPanel?
    private let pairHeading = NSTextField(labelWithString: "Add a Mac")
    private let pairHelp = NSTextField(wrappingLabelWithString: "")
    private let pairBody = NSView()
    private let nearbyTable = NSTableView()
    private let pairButton = NSButton()
    private var nearbyRows: [[String: Any]] = []
    private enum Stage: Equatable { case browsing, connecting, verifying, waiting, expired }
    private var stage = Stage.browsing
    private var requestedService: String?
    private var candidateID: String?
    private var candidateFingerprint = ""
    private var candidateName = "Mac"
    private var confirmAfter = 0.0

    public override init() {
        super.init()
        client.agentManagement = true
        pairHelp.heightAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
        pairBody.heightAnchor.constraint(equalToConstant: 250).isActive = true
        let heading = NSTextField(labelWithString: "Your Macs")
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        let add = button("Add Mac…", #selector(addMac))
        let top = horizontal([heading, NSView(), add])
        let intro = NSTextField(wrappingLabelWithString: "New tabs start on This Mac. Choose another Mac when you want to work there.")
        intro.font = .systemFont(ofSize: 12); intro.textColor = .secondaryLabelColor
        configure(table, identifier: "mac", width: 680)
        table.setAccessibilityLabel("Your workstations")
        table.target = self; table.doubleAction = #selector(openTerminal)
        let list = scroll(table); list.heightAnchor.constraint(equalToConstant: 228).isActive = true
        let terminal = button("New Terminal", #selector(openTerminal))
        let sessions = button("Resume Session…", #selector(openSessions))
        let connection = button("Connection…", #selector(connectionSettings))
        let remove = button("Remove…", #selector(remove))
        actions = [terminal, sessions, connection, remove]
        let controls = horizontal([terminal, sessions, NSView(), connection, remove])
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.heightAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
        let retry = button("Retry Pending Removals", #selector(retryRemovals))
        retry.identifier = .init("pending-removals")
        let details = button("This Mac’s Device ID…", #selector(deviceDetails))
        let bottom = horizontal([retry, NSView(), details])
        let stack = vertical([top, intro, list, controls, status, bottom])
        attach(stack, to: view, inset: 20)
        view.autoresizingMask = [.width]
        client.eventHandler = { [weak self] event in
            if event["type"] as? String == "peers.state" { self?.apply(event) }
        }
        client.connect { [weak self] _ in self?.refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        renderMain()
    }
    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action); b.bezelStyle = .rounded; return b
    }
    private func horizontal(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views); s.orientation = .horizontal; s.alignment = .centerY; s.spacing = 10; return s
    }
    private func vertical(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views); s.orientation = .vertical; s.alignment = .leading; s.spacing = 12
        for v in views { v.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true }
        return s
    }
    private func attach(_ content: NSView, to parent: NSView, inset: CGFloat) {
        content.translatesAutoresizingMaskIntoConstraints = false; parent.addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset), content.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset), content.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset), content.bottomAnchor.constraint(lessThanOrEqualTo: parent.bottomAnchor, constant: -inset)])
    }
    private func configure(_ table: NSTableView, identifier: String, width: CGFloat) {
        let c = NSTableColumn(identifier: .init(identifier)); c.width = width
        table.addTableColumn(c); table.headerView = nil; table.rowHeight = 54
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self; table.delegate = self
    }
    private func scroll(_ table: NSTableView) -> NSScrollView {
        let s = NSScrollView(); s.hasVerticalScroller = true; s.documentView = table; s.borderType = .bezelBorder; return s
    }
    @objc public func refresh() {
        guard client.connected else {
            status.stringValue = "This Mac is available. Other-Mac connections are still starting. Check any TerminalDB permission prompt in macOS."
            return
        }
        client.request("peers.state", payload: [:]) { [weak self] in self?.apply($0) }
    }
    private func message(_ value: String) { feedback = value; feedbackUntil = PeerClock.now + 8; renderMain() }
    private func request(_ operation: String, _ payload: [String: Any] = [:], completion: ((NSDictionary) -> Void)? = nil) {
        client.request(operation, payload: payload as NSDictionary) { [weak self] result in
            guard let self else { return }
            if let error = result["error"] as? String {
                if self.pairPanel != nil { self.pairHelp.stringValue = error; self.stage = .browsing; self.renderNearby() }
                else { self.message(error) }
            } else {
                if result["peers"] != nil { self.apply(result) }
                completion?(result)
            }
        }
    }
    private var selected: [String: Any]? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }
    private var selectedNearby: [String: Any]? { nearbyRows.indices.contains(nearbyTable.selectedRow) ? nearbyRows[nearbyTable.selectedRow] : nil }
    private func apply(_ result: NSDictionary) {
        guard result["peers"] != nil else { return }
        peerInventory = result; renderMain(); changed?()
        guard pairPanel != nil else { return }
        let candidates = result["candidates"] as? [[String: Any]] ?? []
        if !candidateFingerprint.isEmpty,
           (result["peers"] as? [[String: Any]] ?? []).contains(where: { $0["id"] as? String == candidateFingerprint }) {
            preferredSelection = candidateFingerprint
            let name = candidateName
            finishPairingUI(); message("\(name) was added. Select New Terminal to work there."); return
        }
        if result["pairingOpen"] as? Bool != true {
            stage = .expired; pairHelp.stringValue = "Pairing has timed out. Start again on both Macs."; updatePairButton(); return
        }
        if let id = candidateID, let candidate = candidates.first(where: { $0["id"] as? String == id }) {
            if candidate["approvedHere"] as? Bool == true {
                stage = .waiting; pairHelp.stringValue = "Approve on \(candidateName) to finish pairing. Both Macs must agree."; updatePairButton()
            } else if stage == .connecting && candidate["ready"] as? Bool != false {
                showVerification(candidate)
            }
        } else if candidateID != nil {
            if let replacement = candidates.first(where: { $0["fingerprint"] as? String == candidateFingerprint }) {
                candidateID = replacement["id"] as? String; stage = .connecting
                if replacement["ready"] as? Bool != false { showVerification(replacement) }
            } else {
                stage = .expired; pairHelp.stringValue = "The pairing request ended. Start again on both Macs."; updatePairButton(); return
            }
        }
        if stage == .browsing || (stage == .connecting && requestedService == nil) {
            if let candidate = candidates.first(where: { $0["ready"] as? Bool != false && $0["approvedHere"] as? Bool != true }) {
                showVerification(candidate); return
            }
        }
        if stage == .browsing { renderNearby() }
    }
    private func renderMain() {
        let previous = preferredSelection ?? selected?["id"] as? String ?? ""
        preferredSelection = nil
        rows = [["id": "", "name": "This Mac", "kind": "local"]]
        rows += (peerInventory["peers"] as? [[String: Any]] ?? []).map { var r = $0; r["kind"] = "peer"; return r }
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: rows.firstIndex(where: { $0["id"] as? String == previous }) ?? 0), byExtendingSelection: false)
        let pending = peerInventory["pendingRemovals"] as? [String] ?? []
        status.stringValue = !pending.isEmpty ? "Access was removed here. Waiting to update: " + pending.joined(separator: ", ")
            : (PeerClock.now < feedbackUntil ? feedback : "Your Macs connect directly over your network. When away, connect your VPN first. Keep the Mac hosting your work awake and logged in.")
        if let retry = view.subviews.compactMap({ $0 as? NSStackView }).first?.arrangedSubviews.last as? NSStackView {
            retry.arrangedSubviews.first?.isHidden = pending.isEmpty
        }
        updateActions()
    }
    private func updateActions() {
        for b in actions.prefix(2) { b.isEnabled = selected != nil }
        for b in actions.suffix(2) { b.isEnabled = selected?["kind"] as? String == "peer" && client.connected }
    }
    public func numberOfRows(in tableView: NSTableView) -> Int { tableView === table ? rows.count : nearbyRows.count }
    public func tableViewSelectionDidChange(_ notification: Notification) { updateActions(); updatePairButton() }
    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let source = tableView === table ? rows : nearbyRows
        guard source.indices.contains(row) else { return nil }
        let item = source[row]
        let name = TDBWorkstationPresentation.displayName(item["name"] as? String ?? "Nearby Mac")
        let detail: String
        if item["kind"] as? String == "local" { detail = Host.current().localizedName ?? "This computer" }
        else if tableView === table { detail = "Paired Mac" }
        else { detail = item["pairingReady"] as? Bool == false ? "Open Add Mac on the other Mac" : "Ready to pair · " + (item["address"] as? String ?? "Local network") }
        let label = NSTextField(wrappingLabelWithString: name + "\n" + detail)
        label.font = .systemFont(ofSize: 12); label.maximumNumberOfLines = 2; label.lineBreakMode = .byTruncatingMiddle
        return label
    }
    @objc private func openTerminal() {
        guard let selected, let id = selected["id"] as? String else { return }
        openTerminalHandler?(id, selected["name"] as? String ?? "Mac")
    }
    @objc private func openSessions() { if let id = selected?["id"] as? String { openSessionsHandler?(id) } }
    @objc private func addMac() {
        if let pairPanel { pairPanel.makeKeyAndOrderFront(nil); return }
        guard client.connected, let parent = view.window else { refresh(); return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 450), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Add Mac"; pairPanel = panel
        pairHeading.font = .systemFont(ofSize: 20, weight: .semibold)
        pairHeading.stringValue = "Add a Mac"
        pairHelp.stringValue = "On the other Mac, open Workstations → Manage Macs → Add Mac. Choose it below, then compare the fingerprints on both screens."
        pairHelp.font = .systemFont(ofSize: 12)
        if nearbyTable.tableColumns.isEmpty {
            configure(nearbyTable, identifier: "nearby", width: 540)
            nearbyTable.target = self; nearbyTable.doubleAction = #selector(pairAction)
            nearbyTable.setAccessibilityLabel("Macs available for pairing")
        }
        let cancel = button("Cancel", #selector(cancelPairing)); cancel.keyEquivalent = "\u{1b}"
        pairButton.title = "Pair"; pairButton.target = self; pairButton.action = #selector(pairAction); pairButton.bezelStyle = .rounded
        pairButton.keyEquivalent = ""
        let root = vertical([pairHeading, pairHelp, pairBody, horizontal([cancel, NSView(), pairButton])])
        attach(root, to: panel.contentView!, inset: 20)
        stage = .browsing; requestedService = nil; candidateID = nil; candidateFingerprint = ""
        parent.beginSheet(panel) { [weak self] _ in self?.pairPanel = nil }
        renderNearby(); request("peers.pairing.open")
    }
    private func renderNearby() {
        let selection = selectedNearby?["service"] as? String
        let known = Set((peerInventory["peers"] as? [[String: Any]] ?? []).compactMap { ($0["id"] as? String).map { "tdb-" + $0.prefix(12) } })
        nearbyRows = (peerInventory["nearby"] as? [[String: Any]] ?? []).filter { item in
            let service = item["service"] as? String ?? ""
            return !known.contains(where: { service.hasPrefix($0) })
        }
        for v in pairBody.subviews { v.removeFromSuperview() }
        if nearbyRows.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: "No new Macs are ready yet.\nOpen Add Mac on the other Mac and keep both on the same local network.")
            empty.textColor = .secondaryLabelColor; attach(empty, to: pairBody, inset: 16)
        } else {
            let list = scroll(nearbyTable); attach(list, to: pairBody, inset: 0)
            list.bottomAnchor.constraint(equalTo: pairBody.bottomAnchor).isActive = true
            nearbyTable.reloadData()
            if let selection, let row = nearbyRows.firstIndex(where: { $0["service"] as? String == selection }) { nearbyTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            else if selection == nil && nearbyRows.count == 1 { nearbyTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
            else { nearbyTable.deselectAll(nil) }
        }
        updatePairButton()
    }
    private func updatePairButton() {
        guard pairPanel != nil else { return }
        switch stage {
        case .browsing: pairButton.title = "Pair"; pairButton.isEnabled = selectedNearby != nil && selectedNearby?["pairingReady"] as? Bool != false
        case .connecting: pairButton.title = "Connecting…"; pairButton.isEnabled = false
        case .verifying: pairButton.title = "Fingerprints Match — Pair"; pairButton.isEnabled = PeerClock.now >= confirmAfter
        case .waiting: pairButton.title = "Waiting for Other Mac…"; pairButton.isEnabled = false
        case .expired: pairButton.title = "Start Again"; pairButton.isEnabled = true
        }
    }
    @objc private func pairAction() {
        if stage == .expired {
            candidateID = nil; candidateFingerprint = ""; requestedService = nil; stage = .browsing
            pairHeading.stringValue = "Add a Mac"; pairHelp.stringValue = "Open Add Mac on the other Mac too, then choose it below."
            renderNearby(); request("peers.pairing.open"); return
        }
        if stage == .verifying {
            guard PeerClock.now >= confirmAfter, let id = candidateID else { return }
            request("peers.approve", ["candidate": id, "fingerprint": candidateFingerprint]); return
        }
        guard stage == .browsing, let service = selectedNearby?["service"] as? String else { return }
        requestedService = service; stage = .connecting; updatePairButton()
        client.request("peers.pair", payload: ["service": service]) { [weak self] result in
            guard let self, self.pairPanel != nil else { return }
            if let error = result["error"] as? String { self.stage = .browsing; self.pairHelp.stringValue = error; self.renderNearby(); return }
            let candidates = result["candidates"] as? [[String: Any]] ?? []
            if let id = result["requestedCandidate"] as? String,
               let candidate = candidates.first(where: { $0["id"] as? String == id }) { self.candidateID = id; self.candidateFingerprint = candidate["fingerprint"] as? String ?? "" }
            else if candidates.count == 1, let candidate = candidates.first { self.candidateID = candidate["id"] as? String; self.candidateFingerprint = candidate["fingerprint"] as? String ?? "" }
            self.peerInventory = result
            if let candidate = candidates.first(where: { $0["id"] as? String == self.candidateID }), candidate["ready"] as? Bool != false { self.showVerification(candidate) }
        }
    }
    private func showVerification(_ candidate: [String: Any]) {
        guard let id = candidate["id"] as? String, let fingerprint = candidate["fingerprint"] as? String,
              let own = peerInventory["fingerprint"] as? String, own.count == 64, fingerprint.count == 64 else { return }
        candidateID = id; candidateFingerprint = fingerprint
        candidateName = TDBWorkstationPresentation.displayName(candidate["name"] as? String ?? "Other Mac")
        stage = .verifying; confirmAfter = PeerClock.now + max(0.5, NSEvent.doubleClickInterval)
        pairHeading.stringValue = "Check both screens"
        pairHelp.stringValue = "Both Macs must show these same two fingerprints. If either differs, cancel. Select Pair on both Macs only after comparing them."
        for v in pairBody.subviews { v.removeFromSuperview() }
        let ownName = TDBWorkstationPresentation.displayName(Host.current().localizedName ?? "This Mac")
        let entries = [(own, ownName + " · This Mac", "pair-fingerprint-local"), (fingerprint, candidateName, "pair-fingerprint-remote")].sorted { $0.0 < $1.0 }
        var cards: [NSView] = []
        for (value, name, identifier) in entries {
            let title = NSTextField(labelWithString: name); title.font = .systemFont(ofSize: 13, weight: .semibold)
            let groups = stride(from: 0, to: value.count, by: 8).map { offset -> String in let start = value.index(value.startIndex, offsetBy: offset); return String(value[start..<value.index(start, offsetBy: 8)]) }
            let key = NSTextField(wrappingLabelWithString: groups.joined(separator: " "))
            key.font = .monospacedSystemFont(ofSize: 11, weight: .regular); key.isSelectable = true
            key.setAccessibilityIdentifier(identifier); key.setAccessibilityLabel(identifier == "pair-fingerprint-local" ? "This Mac fingerprint" : "Other Mac fingerprint")
            cards += [title, key]
        }
        attach(vertical(cards), to: pairBody, inset: 12); updatePairButton()
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.5, NSEvent.doubleClickInterval)) { [weak self] in self?.updatePairButton() }
    }
    @objc private func cancelPairing() { finishPairingUI() }
    private func finishPairingUI() {
        if let panel = pairPanel { panel.sheetParent?.endSheet(panel); panel.orderOut(nil) }
        pairPanel = nil; candidateID = nil; candidateFingerprint = ""; requestedService = nil; stage = .browsing
        request("peers.pairing.close"); renderMain()
    }
    @objc private func remove() {
        guard let selected, let id = selected["id"] as? String, !id.isEmpty else { return }
        let name = TDBWorkstationPresentation.displayName(selected["name"] as? String ?? "Mac")
        let alert = NSAlert(); alert.messageText = "Remove \(name) from This Mac?"
        alert.informativeText = "Its access to this Mac stops immediately. Running terminals keep going on their hosting Mac. To pair again, remove the pairing on the other Mac too."
        let others = NSButton(checkboxWithTitle: "Also remove it from my other paired Macs", target: nil, action: nil)
        alert.accessoryView = others; alert.addButton(withTitle: "Remove from This Mac"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        request("peers.remove", ["peerId": id, "otherMacs": others.state == .on])
    }
    @objc private func retryRemovals() { request("peers.retryRemovals") }
    @objc private func connectionSettings() {
        guard let selected, let id = selected["id"] as? String, !id.isEmpty, let parent = view.window else { return }
        let name = TDBWorkstationPresentation.displayName(selected["name"] as? String ?? "Mac")
        let alert = NSAlert(); alert.messageText = "\(name) — Connection"
        alert.informativeText = "At home, leave this blank for automatic discovery. For VPN access, enter this Mac’s address on your home network. Connect your VPN before opening a terminal when away."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 460, height: 26))
        field.placeholderString = "LAN address, such as 192.168.1.89 or mac-mini.local"
        field.setAccessibilityLabel("LAN address")
        let endpoints = selected["endpoints"] as? [[String: String]] ?? []
        let saved = endpoints.first(where: { $0["scope"] == "manual" })?["address"] ?? ""
        field.stringValue = saved.hasSuffix(":\(PeerProtocol.defaultPort)") ? String(saved.dropLast(String(PeerProtocol.defaultPort).count + 1)) : saved
        alert.accessoryView = field
        alert.addButton(withTitle: "Save & Test"); alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: parent) { [weak self] response in
            guard let self, response != .alertThirdButtonReturn else { return }
            self.request("peers.endpoint", ["peerId": id, "address": field.stringValue]) { [weak self] _ in
                guard let self else { return }
                if response == .alertFirstButtonReturn {
                    self.message("Testing \(name)…")
                    self.client.request("peers.testAddress", payload: ["peerId": id]) { [weak self] result in
                        self?.message(result["error"] as? String ?? "Connected securely to \(name).")
                    }
                } else { self.message("Connection settings saved for \(name).") }
            }
        }
    }
    @objc private func deviceDetails() {
        let alert = NSAlert(); alert.messageText = "This Mac’s device identity"
        alert.informativeText = "\(Host.current().localizedName ?? "This Mac")\n\nDevice fingerprint:\n\(peerInventory["fingerprint"] as? String ?? "Preparing device identity…")\n\nOnly explicitly paired Macs can open your sessions. Removing a pairing stops its access."
        alert.runModal()
    }
}
