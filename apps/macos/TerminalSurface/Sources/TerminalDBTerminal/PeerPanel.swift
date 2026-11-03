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
            for (socket, executable, identifier) in [
                ("host", "TerminalDBSessionHost", "com.terminaldb.session-host"),
                ("peer", "TerminalDBPeerAgent", "com.terminaldb.peer-agent")
            ] {
                // Retire the 0.6.0 agent only when it is stopped. A live
                // legacy host continues serving its existing shells.
                let legacy = SMAppService.agent(plistName: identifier + ".plist")
                if legacy.status == .requiresApproval {
                    throw PeerFailure("Enable TerminalDB in System Settings → General → Login Items & Extensions, then reopen it.")
                }
                if legacy.status == .enabled,
                   try await !repairStoppedService(legacy, socket: socket, executable: executable, reregister: false) {
                    continue
                }
                let service = SMAppService.loginItem(identifier: identifier)
                if service.status == .enabled {
                    _ = try await repairStoppedService(service, socket: socket, executable: executable)
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
    @MainActor private static func repairStoppedService(_ service: SMAppService, socket: String, executable: String, reregister: Bool = true) async throws -> Bool {
        let fd = Darwin.open(PeerPaths.file(socket + ".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw PeerFailure("TerminalDB could not check its background service. Check this user’s Application Support permissions.") }
        defer { Darwin.close(fd) }
        // A live host's lease protects its shells, even when its UI/IPC is slow.
        // Hold an unowned lease until unregister finishes so no new work can
        // start in the old registration during repair.
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return false }
        defer { flock(fd, LOCK_UN) }
        let paths = [helperURL(executable).path,
                     Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/" + executable).path,
                     Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(executable).app/Contents/MacOS/\(executable)").path]
        let capacity = max(1024, Int(proc_listallpids(nil, 0)) + 256)
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count >= 0 else { return false }
        for pid in pids.prefix(min(Int(count), capacity)) where pid > 0 {
            var name = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pid, &name, UInt32(name.count)) > 0 && paths.contains(String(cString: name)) {
                return false // Includes a helper waiting on its macOS Keychain prompt.
            }
        }
        // macOS can retain an enabled registration pointing at a replaced
        // bundle. Refresh only a stopped service; never stop a running host.
        // The synchronous API returns before launchd/BTM has retired the old
        // process and signing constraint. Only the async completion makes it
        // safe to register the new executable's signature after an update.
        try await service.unregister()
        flock(fd, LOCK_UN)
        if reregister { try service.register() }
        return true
    }
    private static func helperURL(_ executable: String) -> URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LoginItems/\(executable).app/Contents/MacOS/\(executable)")
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
    private let pairCancel = NSButton()
    private let pairDetails = NSButton()
    private var pairBodyHeight: NSLayoutConstraint!
    private var nearbySignature = ""
    private var mainSignature = ""
    private var nearbyRows: [[String: Any]] = []
    private typealias Stage = PairingPresentation.Stage
    private var pairing = PairingPresentation()
    private var stage: Stage { get { pairing.stage } set { pairing.stage = newValue } }
    private var requestedService: String?
    private var candidateID: String?
    private var candidateFingerprint = ""
    private var candidateName = "Mac"
    private var confirmAfter = 0.0

    public override init() {
        super.init()
        client.agentManagement = true
        pairHelp.font = .systemFont(ofSize: 13); pairHelp.textColor = .secondaryLabelColor
        pairHelp.preferredMaxLayoutWidth = 512
        pairBodyHeight = pairBody.heightAnchor.constraint(equalToConstant: 180)
        pairBodyHeight.isActive = true
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
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        status.heightAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
        let retry = button("Retry Pending Removals", #selector(retryRemovals))
        retry.identifier = .init("pending-removals")
        let details = button("This Mac’s Device ID…", #selector(deviceDetails))
        let bottom = horizontal([retry, NSView(), details])
        let stack = vertical([top, intro, list, controls, status, bottom])
        attach(stack, to: view, inset: 20)
        view.autoresizingMask = [.width]
        client.eventHandler = { [weak self] event in
            guard let self else { return }
            if event["type"] as? String == "peers.state" { self.apply(event) }
            else if ["disconnected", "connection-error"].contains(event["type"] as? String ?? ""),
                    self.pairPanel != nil, self.stage != .expired, self.stage != .connected {
                self.expirePairingUI()
                self.pairHelp.stringValue = "Nearby connections are unavailable. Check this Mac’s TerminalDB background service, then search again."
            }
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
        let generation = pairing.generation
        let approvalCandidate = payload["candidate"] as? String
        client.request(operation, payload: payload as NSDictionary) { [weak self] result in
            guard let self else { return }
            if operation == "peers.pairing.close", generation != self.pairing.generation { return }
            if operation == "peers.approve" {
                guard self.pairPanel != nil, generation == self.pairing.generation,
                      self.candidateID == approvalCandidate, self.stage == .verifying || self.stage == .waiting else { return }
            }
            if let error = result["error"] as? String {
                if self.pairPanel != nil { self.expirePairingUI(); self.pairHelp.stringValue = error }
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
        if pairPanel != nil {
            if stage != .opening, stage != .expired, stage != .connected,
               let expected = pairing.remoteGeneration, let actual = result["pairingGeneration"] as? Int, actual > expected {
                expirePairingUI(); return
            }
            guard pairing.accepts(remote: result["pairingGeneration"] as? Int) else { return }
        }
        peerInventory = result; renderMain(); changed?()
        guard pairPanel != nil else { return }
        if stage == .connected || stage == .expired { return }
        let candidates = result["candidates"] as? [[String: Any]] ?? []
        if !candidateFingerprint.isEmpty,
           (result["peers"] as? [[String: Any]] ?? []).contains(where: { $0["id"] as? String == candidateFingerprint }) {
            preferredSelection = candidateFingerprint
            stage = .connected
            showPairStatus(title: "\(candidateName) is connected", detail: "Open a terminal to start working on that Mac.", symbol: "checkmark.circle")
            updatePairButton(); return
        }
        if result["pairingOpen"] as? Bool != true {
            expirePairingUI(); return
        }
        if let id = candidateID, let candidate = candidates.first(where: { $0["id"] as? String == id }) {
            if candidate["approvedHere"] as? Bool == true {
                stage = .waiting; pairHeading.stringValue = "Approve on \(candidateName)"
                pairHelp.stringValue = "Approved here. Compare these fingerprints on the other Mac, then approve there to finish."
                updatePairButton()
            } else if stage == .connecting && candidate["ready"] as? Bool != false {
                showVerification(candidate)
            }
        } else if candidateID != nil {
            if let replacement = candidates.first(where: { $0["fingerprint"] as? String == candidateFingerprint }) {
                candidateID = replacement["id"] as? String; stage = .connecting
                if replacement["ready"] as? Bool != false { showVerification(replacement) }
            } else {
                expirePairingUI(); return
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
        let signature = String(data: (try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])) ?? Data(), encoding: .utf8) ?? ""
        if signature != mainSignature { mainSignature = signature; table.reloadData() }
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
        else {
            let sameNames = source.filter { TDBWorkstationPresentation.displayName($0["name"] as? String ?? "Mac") == name }
            let ordinal = sameNames.firstIndex(where: { $0["service"] as? String == item["service"] as? String }).map { $0 + 1 } ?? 1
            detail = sameNames.count > 1 ? "Ready to pair · Connection \(ordinal)" : "Ready to pair"
        }
        let title = NSTextField(labelWithString: name)
        title.font = .systemFont(ofSize: 13, weight: .medium); title.lineBreakMode = .byTruncatingMiddle
        let subtitle = NSTextField(labelWithString: detail)
        subtitle.font = .systemFont(ofSize: 12); subtitle.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [title, subtitle]); labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 2
        for label in [title, subtitle] {
            label.widthAnchor.constraint(lessThanOrEqualTo: labels.widthAnchor).isActive = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let icon = NSImageView(image: NSImage(systemSymbolName: item["kind"] as? String == "local" ? "laptopcomputer" : "desktopcomputer", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
        let cell = NSTableCellView()
        let content = horizontal([icon, labels]); attach(content, to: cell, inset: 8)
        title.setAccessibilityLabel(name + ", " + detail)
        return cell
    }
    @objc private func openTerminal() {
        guard let selected, let id = selected["id"] as? String else { return }
        openTerminalHandler?(id, selected["name"] as? String ?? "Mac")
    }
    @objc private func openSessions() { if let id = selected?["id"] as? String { openSessionsHandler?(id) } }
    @objc public func addMac() {
        if let pairPanel { pairPanel.makeKeyAndOrderFront(nil); return }
        guard client.connected, let parent = view.window else { refresh(); return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 450), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Add Mac"; pairPanel = panel
        pairHeading.font = .systemFont(ofSize: 20, weight: .semibold)
        pairHeading.maximumNumberOfLines = 2; pairHeading.lineBreakMode = .byTruncatingMiddle
        if nearbyTable.tableColumns.isEmpty {
            configure(nearbyTable, identifier: "nearby", width: 500)
            nearbyTable.target = self; nearbyTable.doubleAction = #selector(pairAction)
            nearbyTable.setAccessibilityLabel("Macs available for pairing")
        }
        pairCancel.title = "Cancel"; pairCancel.target = self; pairCancel.action = #selector(cancelPairing)
        pairCancel.bezelStyle = .rounded; pairCancel.keyEquivalent = "\u{1b}"
        pairDetails.title = "Connection Details…"; pairDetails.target = self; pairDetails.action = #selector(pairConnectionDetails)
        pairDetails.bezelStyle = .rounded
        pairButton.title = "Pair"; pairButton.target = self; pairButton.action = #selector(pairAction); pairButton.bezelStyle = .rounded
        pairButton.keyEquivalent = ""
        let root = vertical([pairHeading, pairHelp, pairBody, horizontal([pairCancel, pairDetails, NSView(), pairButton])])
        attach(root, to: panel.contentView!, inset: 24)
        parent.beginSheet(panel) { [weak self] _ in self?.pairPanel = nil }
        startPairingSearch()
    }
    private func startPairingSearch() {
        candidateID = nil; candidateFingerprint = ""; requestedService = nil; nearbyRows = []; nearbySignature = ""
        let generation = pairing.begin()
        showPairStatus(title: "Find a Mac", detail: "Preparing nearby discovery…", symbol: nil)
        updatePairButton()
        client.request("peers.pairing.open", payload: [:]) { [weak self] result in
            guard let self, self.pairPanel != nil, generation == self.pairing.generation else { return }
            if let error = result["error"] as? String {
                self.stage = .expired
                self.showPairStatus(title: "Couldn’t start pairing", detail: error, symbol: "exclamationmark.circle")
                self.updatePairButton(); return
            }
            guard result["pairingOpen"] as? Bool == true else { self.expirePairingUI(); return }
            guard self.pairing.opened(generation: generation, remote: result["pairingGeneration"] as? Int) else { return }
            self.apply(result); self.renderNearby()
        }
    }
    private func clearPairBody() {
        for view in pairBody.subviews { view.removeFromSuperview() }
        nearbySignature = ""
    }
    private func showPairStatus(title: String, detail: String, symbol: String?) {
        pairHeading.stringValue = title; pairHelp.stringValue = detail
        clearPairBody(); pairBodyHeight.constant = 48
        if let symbol {
            let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
            image.contentTintColor = .secondaryLabelColor
            image.translatesAutoresizingMaskIntoConstraints = false; pairBody.addSubview(image)
            NSLayoutConstraint.activate([image.centerXAnchor.constraint(equalTo: pairBody.centerXAnchor), image.centerYAnchor.constraint(equalTo: pairBody.centerYAnchor), image.widthAnchor.constraint(equalToConstant: 32), image.heightAnchor.constraint(equalToConstant: 32)])
        } else {
            let progress = NSProgressIndicator(); progress.style = .spinning; progress.controlSize = .regular
            progress.translatesAutoresizingMaskIntoConstraints = false; pairBody.addSubview(progress)
            NSLayoutConstraint.activate([progress.centerXAnchor.constraint(equalTo: pairBody.centerXAnchor), progress.centerYAnchor.constraint(equalTo: pairBody.centerYAnchor)])
            progress.startAnimation(nil)
        }
        resizePairPanel()
    }
    private func resizePairPanel() {
        guard let panel = pairPanel, let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        guard let stack = content.subviews.first as? NSStackView else { return }
        let height = max(240, stack.fittingSize.height + 48)
        panel.setContentSize(NSSize(width: 560, height: min(560, height)))
    }
    private func expirePairingUI() {
        candidateID = nil; candidateFingerprint = ""; requestedService = nil; nearbyRows = []
        stage = .expired
        showPairStatus(title: "Pairing expired", detail: "Search again to continue. If the other Mac isn’t listed, open Add Mac there.", symbol: "clock")
        updatePairButton()
    }
    @objc private func pairConnectionDetails() {
        guard stage == .browsing, let selected = selectedNearby, let panel = pairPanel else { return }
        let alert = NSAlert(); alert.messageText = TDBWorkstationPresentation.displayName(selected["name"] as? String ?? "Mac")
        alert.informativeText = "Local network connection\n\(selected["address"] as? String ?? "Address unavailable")\n\nThe device is verified by comparing fingerprints on both Macs, not by its name or address."
        alert.addButton(withTitle: "Done"); alert.beginSheetModal(for: panel)
    }
    private func renderNearby() {
        guard pairPanel != nil, stage == .browsing else { return }
        let selection = selectedNearby?["service"] as? String
        let qa = ProcessInfo.processInfo.environment["TERMINALDB_PEER_EPHEMERAL_IDENTITY"] == "1"
        let next = pairing.visibleChoices(peerInventory as? [String: Any] ?? [:], allowTestInstances: qa)
        let signature = String(data: (try? JSONSerialization.data(withJSONObject: next, options: [.sortedKeys])) ?? Data(), encoding: .utf8) ?? ""
        pairHeading.stringValue = "Choose a Mac"
        pairHelp.stringValue = "On your other Mac, choose TerminalDB → Workstations → Add Mac. Keep both Macs on the same local network."
        if signature == nearbySignature { updatePairButton(); return }
        clearPairBody(); nearbySignature = signature; nearbyRows = next
        if nearbyRows.isEmpty {
            pairBodyHeight.constant = 162
            let empty = NSTextField(wrappingLabelWithString: "Looking for Macs…")
            empty.font = .systemFont(ofSize: 13); empty.textColor = .secondaryLabelColor
            empty.alignment = .center; attach(empty, to: pairBody, inset: 32)
        } else {
            // Discovery updates must not move Continue under the pointer.
            pairBodyHeight.constant = 162
            let list = scroll(nearbyTable); attach(list, to: pairBody, inset: 0)
            list.bottomAnchor.constraint(equalTo: pairBody.bottomAnchor).isActive = true
            nearbyTable.reloadData()
            let nextSelection = PairingPresentation.selection(in: nearbyRows, previous: selection)
            if let nextSelection, let row = nearbyRows.firstIndex(where: { $0["service"] as? String == nextSelection }) { nearbyTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            else { nearbyTable.deselectAll(nil) }
        }
        updatePairButton(); resizePairPanel()
    }
    private func updatePairButton() {
        guard pairPanel != nil else { return }
        pairCancel.title = stage == .connected ? "Done" : "Cancel"
        pairDetails.isHidden = stage != .browsing || selectedNearby == nil
        pairButton.keyEquivalent = ""
        switch stage {
        case .opening: pairButton.title = "Searching…"; pairButton.isEnabled = false
        case .browsing:
            pairButton.title = "Continue"; pairButton.isEnabled = selectedNearby != nil
            pairButton.keyEquivalent = "\r"
        case .connecting: pairButton.title = "Connecting…"; pairButton.isEnabled = false
        case .verifying: pairButton.title = "Fingerprints Match — Pair"; pairButton.isEnabled = PeerClock.now >= confirmAfter
        case .waiting: pairButton.title = "Waiting for Approval…"; pairButton.isEnabled = false
        case .expired: pairButton.title = "Search Again"; pairButton.isEnabled = true; pairButton.keyEquivalent = "\r"
        case .connected: pairButton.title = "Open Terminal"; pairButton.isEnabled = true; pairButton.keyEquivalent = "\r"
        }
    }
    private var pairingPayload: [String: Any] { pairing.remoteGeneration.map { ["pairingGeneration": $0] } ?? [:] }
    @objc private func pairAction() {
        if stage == .expired {
            startPairingSearch(); return
        }
        if stage == .connected {
            let id = candidateFingerprint, name = candidateName
            finishPairingUI(); openTerminalHandler?(id, name); return
        }
        if stage == .verifying {
            guard PeerClock.now >= confirmAfter, let id = candidateID else { return }
            var payload = pairingPayload; payload["candidate"] = id; payload["fingerprint"] = candidateFingerprint
            request("peers.approve", payload); return
        }
        guard stage == .browsing, let selected = selectedNearby, let service = selected["service"] as? String else { return }
        candidateName = TDBWorkstationPresentation.displayName(selected["name"] as? String ?? "Mac")
        requestedService = service; stage = .connecting
        let generation = pairing.generation
        showPairStatus(title: "Connecting to \(candidateName)", detail: "Keep Add Mac open on both Macs while the secure connection starts.", symbol: nil)
        updatePairButton()
        var payload = pairingPayload; payload["service"] = service
        client.request("peers.pair", payload: payload as NSDictionary) { [weak self] result in
            guard let self, self.pairPanel != nil, generation == self.pairing.generation, self.stage == .connecting else { return }
            if let error = result["error"] as? String { self.stage = .browsing; self.renderNearby(); self.pairHelp.stringValue = error; return }
            guard self.pairing.accepts(remote: result["pairingGeneration"] as? Int) else { return }
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
        pairHelp.stringValue = "Both Macs must show these same two fingerprints. Compare every group, then approve on both Macs. Cancel if either differs."
        clearPairBody(); pairBodyHeight.constant = 210
        let ownName = TDBWorkstationPresentation.displayName(Host.current().localizedName ?? "This Mac")
        let entries = [(own, ownName + " · This Mac", "pair-fingerprint-local"), (fingerprint, candidateName, "pair-fingerprint-remote")].sorted { $0.0 < $1.0 }
        var cards: [NSView] = []
        for (value, name, identifier) in entries {
            let title = NSTextField(labelWithString: name); title.font = .systemFont(ofSize: 13, weight: .semibold)
            let groups = stride(from: 0, to: value.count, by: 8).map { offset -> String in let start = value.index(value.startIndex, offsetBy: offset); return String(value[start..<value.index(start, offsetBy: 8)]) }
            let key = NSTextField(wrappingLabelWithString: groups.joined(separator: " "))
            key.font = .monospacedSystemFont(ofSize: 12, weight: .regular); key.isSelectable = true; key.preferredMaxLayoutWidth = 488
            key.setAccessibilityIdentifier(identifier); key.setAccessibilityLabel(identifier == "pair-fingerprint-local" ? "This Mac fingerprint" : "Other Mac fingerprint")
            cards += [title, key]
        }
        attach(vertical(cards), to: pairBody, inset: 12); updatePairButton(); resizePairPanel()
        let generation = pairing.generation
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.5, NSEvent.doubleClickInterval)) { [weak self] in
            guard let self, generation == self.pairing.generation else { return }; self.updatePairButton()
        }
    }
    @objc private func cancelPairing() { finishPairingUI() }
    private func finishPairingUI() {
        let payload = pairingPayload
        if let panel = pairPanel { panel.sheetParent?.endSheet(panel); panel.orderOut(nil) }
        pairPanel = nil; pairing.cancel(); clearPairBody(); nearbyRows = []
        candidateID = nil; candidateFingerprint = ""; requestedService = nil
        request("peers.pairing.close", payload); renderMain()
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
