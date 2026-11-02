import AppKit

private final class AWSAccessList: NSStackView {
    override var isFlipped: Bool { true }
}

@objc(TDBAWSAccessPanel)
public final class TDBAWSAccessPanel: NSObject, NSWindowDelegate {
    private static var current: TDBAWSAccessPanel?
    private let panel: NSPanel
    private let host = TDBSessionClient()
    private let agent = TDBSessionClient()
    private let list = AWSAccessList()
    private let scroll = NSScrollView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let subtitle = NSTextField(wrappingLabelWithString: "")
    private let tabs = NSSegmentedControl(labels: ["Profiles", "Sync Macs"], trackingMode: .selectOne, target: nil, action: nil)
    private let cancel = NSButton(title: "Cancel Sign-In", target: nil, action: nil)
    private var timer: Timer?
    private var rowsSignature = ""
    private var choices: [(String, NSButton)] = []
    private var actions: [String: () -> Void] = [:]
    private var catalog: [String: Any] = [:]
    private var peerState: [String: Any] = [:]
    private var pending = false
    private var syncDraft: Set<String>?
    private var syncSaving = false
    private var closeAfterSync = false
    private var actionError: String?

    @objc public static func present() {
        if let current { current.panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let view = TDBAWSAccessPanel(); current = view; view.show()
    }

    private override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 700, height: 650),
                        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        panel.title = "AWS Access — " + PeerProtocol.displayName(Host.current().localizedName ?? "This Mac")
        panel.isReleasedWhenClosed = false; panel.delegate = self
        let title = NSTextField(labelWithString: "AWS profiles on This Mac")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        subtitle.textColor = .secondaryLabelColor
        tabs.selectedSegment = 0; tabs.target = self; tabs.action = #selector(changeTab)
        tabs.setAccessibilityLabel("AWS access view")
        list.orientation = .vertical; list.alignment = .leading; list.spacing = 12
        list.identifier = .init("AWSProfiles")
        scroll.documentView = list; scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 290).isActive = true
        let note = label("Each Mac keeps temporary access until AWS’s expiry time. Renewal needs a reachable, signed-in Mac. You can sign in on any Mac.", small: true)
        let done = NSButton(title: "Done", target: self, action: #selector(closePanel)); done.keyEquivalent = "\u{1b}"
        cancel.target = self; cancel.action = #selector(cancelSignIn); cancel.isHidden = true
        let footer = NSStackView(views: [cancel, NSView(), done]); footer.orientation = .horizontal
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        status.setAccessibilityLabel("AWS access status")
        let stack = NSStackView(views: [title, subtitle, tabs, scroll, note, status, footer])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = panel.contentView!; content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22)
        ])
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        panel.minSize = NSSize(width: 640, height: 600)
        agent.agentManagement = true
        updateSubtitle()
    }

    private func show() {
        panel.center(); panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        host.connect { [weak self] _ in self?.refresh() }
        agent.connect { [weak self] _ in self?.refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    private func label(_ text: String, small: Bool = false) -> NSTextField {
        let view = NSTextField(wrappingLabelWithString: text)
        view.textColor = .secondaryLabelColor
        view.font = .systemFont(ofSize: small ? 11 : 12)
        return view
    }

    private func updateSubtitle() {
        subtitle.stringValue = tabs.selectedSegment == 0
            ? "Use these profiles in commands on This Mac. Your AWS browser sign-in stays on the Mac where you sign in."
            : "Choose the paired Macs allowed to exchange selected AWS profiles. Enable AWS sync on both Macs. Claude sync settings are separate."
    }

    @objc private func changeTab() {
        rowsSignature = ""; updateSubtitle(); render(); refresh()
    }

    private func refresh() {
        if host.connected {
            host.request("aws.catalog", payload: [:]) { [weak self] result in
                guard let self else { return }
                if let error = result["error"] as? String { self.status.stringValue = error; return }
                self.catalog = result as? [String: Any] ?? [:]
                self.cancel.isHidden = (result["signInProfile"] as? String ?? "").isEmpty
                if let error = self.actionError { self.status.stringValue = error }
                else if !self.pending, let phase = result["phase"] as? String, !phase.isEmpty { self.status.stringValue = phase }
                else if self.status.stringValue == "Waiting for this Mac’s background service…" { self.status.stringValue = "" }
                self.render()
            }
        } else { status.stringValue = "Waiting for this Mac’s background service…" }
        if agent.connected {
            agent.request("peers.state", payload: [:]) { [weak self] result in
                self?.peerState = result as? [String: Any] ?? [:]; self?.render()
            }
        }
    }

    private func clearRows() {
        for view in list.arrangedSubviews { list.removeArrangedSubview(view); view.removeFromSuperview() }
        actions.removeAll(); choices.removeAll()
    }

    private func addRow(_ row: NSStackView) {
        row.orientation = .vertical; row.alignment = .leading; row.spacing = 6
        row.setHuggingPriority(.required, for: .vertical)
        list.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor, constant: -12).isActive = true
        for view in row.arrangedSubviews { view.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true }
    }

    private func button(_ title: String, action: @escaping () -> Void) -> NSButton {
        let value = NSButton(title: title, target: self, action: #selector(invokeAction(_:)))
        let id = UUID().uuidString; value.identifier = .init(id); actions[id] = action
        value.isEnabled = !pending
        return value
    }
    private func signInButton(_ title: String, profile: String) -> NSButton {
        let value = button(title) { [weak self] in self?.request("aws.signIn.start", ["profileId": profile]) }
        value.isEnabled = value.isEnabled && (catalog["signInProfile"] as? String ?? "").isEmpty
        return value
    }

    @objc private func invokeAction(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }; actions[id]?()
    }

    private func render() {
        let syncing = tabs.selectedSegment == 1
        var body: [String: Any]
        if syncing {
            let enabled = syncDraft.map { Array($0).sorted() } ?? (peerState["awsPeers"] as? [String] ?? [])
            body = ["peers": peerState["peers"] ?? [], "enabled": enabled, "states": peerState["awsStatus"] ?? [:]]
        } else {
            body = ["profiles": catalog["profiles"] ?? [], "accounts": catalog["accounts"] ?? [],
                    "installed": catalog["installed"] ?? [], "sourceStatus": catalog["sourceStatus"] ?? [:],
                    "sources": catalog["sources"] ?? [], "signIn": catalog["signInProfile"] ?? ""]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return }
        let signature = "\(syncing):\(pending):" + String(decoding: data, as: UTF8.self)
        guard signature != rowsSignature else { return }
        rowsSignature = signature; clearRows()
        if syncing { renderMacs() } else { renderProfiles() }
        list.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: list.fittingSize.height)
    }

    private func renderMacs() {
        let peers = peerState["peers"] as? [[String: Any]] ?? []
        let enabled = syncDraft ?? Set(peerState["awsPeers"] as? [String] ?? [])
        let states = peerState["awsStatus"] as? [String: String] ?? [:]
        if peers.isEmpty {
            addRow(NSStackView(views: [label("Pair another Mac from TerminalDB → Workstations → Add Mac first.")]))
        }
        for peer in peers {
            guard let id = peer["id"] as? String, let name = peer["name"] as? String else { continue }
            let choice = NSButton(checkboxWithTitle: name, target: self, action: #selector(syncMacChanged(_:)))
            choice.state = enabled.contains(id) ? .on : .off
            choices.append((id, choice))
            addRow(NSStackView(views: [choice, label(states[id] ?? (enabled.contains(id) ? "Waiting for the other Mac" : "AWS sync is off"))]))
        }
        addRow(NSStackView(views: [label("Macs exchange profiles shared here and profiles received from other approved Macs. Turning sync off stops future transfers; copied credentials remain valid until AWS expires or revokes them.", small: true)]))
    }

    private func renderProfiles() {
        let profiles = catalog["profiles"] as? [[String: Any]] ?? []
        let accounts = catalog["accounts"] as? [[String: Any]] ?? []
        let installed = catalog["installed"] as? [[String: Any]] ?? []
        let sources = Set(catalog["sources"] as? [String] ?? [])
        let states = catalog["sourceStatus"] as? [String: String] ?? [:]
        var descriptors: [String: [String: Any]] = [:]
        for p in profiles { if let id = p["id"] as? String { descriptors[id] = p } }
        for a in accounts {
            if let id = a["profileId"] as? String, let d = a["descriptor"] as? [String: Any] { descriptors[id] = d }
        }
        for item in installed {
            if let id = item["profileId"] as? String, let d = item["descriptor"] as? [String: Any], descriptors[id] == nil {
                descriptors[id] = d
            }
        }
        if descriptors.isEmpty {
            addRow(NSStackView(views: [label("No AWS profiles are available yet. Configure an AWS SSO or console-login profile with the AWS CLI, or enable Sync Macs to receive a shared profile.")]))
            return
        }
        for (id, descriptor) in descriptors.sorted(by: { ($0.value["name"] as? String ?? "") < ($1.value["name"] as? String ?? "") }) {
            let account = accounts.first { $0["profileId"] as? String == id }
            let mapping = installed.first { $0["profileId"] as? String == id }
            let source = sources.contains(id)
            let local = profiles.contains { $0["id"] as? String == id }
            let name = mapping?["targetName"] as? String ?? descriptor["name"] as? String ?? "AWS profile"
            let title = NSTextField(labelWithString: name); title.font = .systemFont(ofSize: 16, weight: .semibold)
            let details = [descriptor["accountID"] as? String, descriptor["roleName"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            let row = NSStackView(views: [title])
            if !details.isEmpty { row.addArrangedSubview(label(details)) }
            var availability = states[id] ?? account?["status"] as? String ?? "Not shared yet"
            if let expires = account?["expires"] as? Double, account?["available"] as? Bool == true {
                let time = DateFormatter.localizedString(from: Date(timeIntervalSince1970: expires), dateStyle: .none, timeStyle: .short)
                availability = "Temporary access available · Expires \(time)"
                if states[id] == "Sign in on this Mac to renew" { availability += " · Sign in here to renew" }
            }
            row.addArrangedSubview(label(availability))
            if let source = account?["sourceName"] as? String, !source.isEmpty { row.addArrangedSubview(label("Provided by \(source)", small: true)) }
            let buttons = NSStackView(); buttons.orientation = .horizontal; buttons.spacing = 8
            if mapping == nil && !source && account?["available"] as? Bool != true && local {
                buttons.addArrangedSubview(signInButton("Sign In", profile: id))
                buttons.addArrangedSubview(button("Share Current Sign-In") { [weak self] in self?.request("aws.source.enable", ["profileId": id]) })
            } else if mapping == nil && !source {
                buttons.addArrangedSubview(button("Use on This Mac…") { [weak self] in
                    self?.install(id: id, name: descriptor["name"] as? String ?? name, local: local)
                })
            } else {
                buttons.addArrangedSubview(signInButton("Sign In on This Mac", profile: id))
                if source {
                    buttons.addArrangedSubview(button("Refresh") { [weak self] in self?.request("aws.refresh", ["profileId": id]) })
                } else {
                    buttons.addArrangedSubview(button("Sync Now") { [weak self] in self?.syncNow() })
                }
                buttons.addArrangedSubview(button("Remove…") { [weak self] in self?.remove(id: id, name: name) })
            }
            row.addArrangedSubview(buttons)
            let divider = NSBox(); divider.boxType = .separator
            divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
            row.addArrangedSubview(divider)
            addRow(row)
        }
    }

    private func install(id: String, name: String, local: Bool) {
        let alert = NSAlert()
        alert.messageText = "Use \(name) on This Mac?"
        alert.informativeText = "Ordinary AWS commands will use the name below with --profile. If you keep an existing name, future browser sign-ins happen through TerminalDB’s Sign In button. Its original settings are backed up. Choose a different name to keep your current AWS login commands."
        let field = NSTextField(string: name); field.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
        field.setAccessibilityLabel("AWS profile name on This Mac"); alert.accessoryView = field
        alert.addButton(withTitle: "Use Profile"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: panel) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.request("aws.use", ["profileId": id, "targetName": field.stringValue, "replaceSource": local && field.stringValue == name])
        }
    }

    private func remove(id: String, name: String) {
        let alert = NSAlert(); alert.messageText = "Remove \(name) from TerminalDB on This Mac?"
        alert.informativeText = "This stops publishing this Mac’s access and restores its original profile when safe. It does not sign out of unrelated AWS profiles or revoke temporary credentials already copied to other Macs."
        alert.addButton(withTitle: "Remove Profile"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: panel) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.request("aws.remove", ["profileId": id]) }
        }
    }

    private func request(_ operation: String, _ payload: [String: Any]) {
        guard !pending else { return }; pending = true; rowsSignature = ""; render()
        actionError = nil
        status.stringValue = operation == "aws.signIn.start" ? "Starting AWS sign-in in your browser on This Mac…" : "Updating AWS access…"
        host.request(operation, payload: payload as NSDictionary) { [weak self] result in
            guard let self else { return }; self.pending = false; self.rowsSignature = ""
            self.actionError = result["error"] as? String
            self.status.stringValue = self.actionError ?? "Saved. Approved Macs sync automatically over your LAN or VPN."
            self.agent.request("aws.sync.now", payload: [:]) { _ in }
            self.refresh()
        }
    }

    @objc private func syncMacChanged(_ sender: NSButton) {
        guard let id = choices.first(where: { $0.1 === sender })?.0 else { return }
        var desired = syncDraft ?? Set(peerState["awsPeers"] as? [String] ?? [])
        if sender.state == .on { desired.insert(id) } else { desired.remove(id) }
        syncDraft = desired
        actionError = nil
        saveSync()
    }
    private func saveSync() {
        guard !syncSaving, let desired = syncDraft else { return }
        syncSaving = true
        let peers = Array(desired).sorted()
        agent.request("aws.sync.configure", payload: ["peers": peers]) { [weak self] result in
            guard let self else { return }
            self.syncSaving = false
            if let error = result["error"] as? String {
                self.syncDraft = nil; self.actionError = error; self.status.stringValue = error
                self.closeAfterSync = false
            } else {
                self.peerState = result as? [String: Any] ?? self.peerState
                if self.syncDraft != desired { self.saveSync(); return }
                self.syncDraft = nil
                self.status.stringValue = "Saved. Enable AWS sync on the other Mac too."
                if self.closeAfterSync { self.panel.close(); return }
            }
            self.rowsSignature = ""
            self.refresh()
        }
    }
    private func syncNow() {
        actionError = nil
        agent.request("aws.sync.now", payload: [:]) { [weak self] result in
            self?.actionError = result["error"] as? String
            self?.status.stringValue = result["error"] as? String ?? "Checking your approved Macs for updated access…"
            self?.refresh()
        }
    }
    @objc private func cancelSignIn() { request("aws.signIn.cancel", [:]) }
    private func prepareClose() -> Bool {
        guard !syncSaving, syncDraft == nil else {
            closeAfterSync = true; status.stringValue = "Saving AWS sync settings…"; return false
        }
        return true
    }
    public func windowShouldClose(_ sender: NSWindow) -> Bool { prepareClose() }
    @objc private func closePanel() { if prepareClose() { panel.close() } }
    public func windowWillClose(_ notification: Notification) {
        timer?.invalidate(); timer = nil; host.close(); agent.close(); Self.current = nil
    }
}
