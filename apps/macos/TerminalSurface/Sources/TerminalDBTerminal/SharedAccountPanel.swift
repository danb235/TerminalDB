import AppKit

private final class SharedAccountList: NSStackView {
    override var isFlipped: Bool { true }
}

@objc(TDBSharedAccountPanel)
public final class TDBSharedAccountPanel: NSObject, NSWindowDelegate {
    private static var current: TDBSharedAccountPanel?
    private let panel: NSPanel
    private let client = TDBSessionClient()
    private let name = NSTextField(string: "")
    private let email = NSTextField(string: "")
    private let organization = NSTextField(string: "")
    private var organizationFields: NSStackView?
    private var organizationRow: NSStackView?
    private let footer = NSStackView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var timer: Timer?
    private var choices: [(String, NSButton)] = []
    private var syncDetails: [String: NSTextField] = [:]
    private let syncList = SharedAccountList()
    private let syncScroll = NSScrollView()
    private var syncRows: [String: NSView] = [:]
    private var peerState: NSDictionary = [:]
    private var syncDraft: Set<String>?
    private var syncSaving = false
    private var closeAfterSync = false
    private var syncRevision = 0
    private var actionError: String?
    private var afterClose: (() -> Void)?
    private let signInButton = NSButton(title: "Sign In in Browser", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel Sign-In", target: nil, action: nil)
    private let organizationToggle = NSButton(title: "Organization…", target: nil, action: nil)
    private var executable = ""
    private var account: [String: Any] = [:]
    private var syncing = false

    @objc(presentSignIn:executable:)
    public static func presentSignIn(_ account: NSDictionary, executable: String) {
        if let current, !current.prepareClose() {
            current.afterClose = { presentSignIn(account, executable: executable) }; return
        }
        current?.panel.close()
        let view = TDBSharedAccountPanel(sync: false)
        current = view; view.account = account as? [String: Any] ?? [:]; view.executable = executable
        view.name.stringValue = view.account["label"] as? String ?? ""
        view.email.stringValue = view.account["email"] as? String ?? ""
        view.organization.stringValue = view.account["organization"] as? String ?? ""
        if !view.organization.stringValue.isEmpty {
            view.organizationFields?.isHidden = true; view.organizationRow?.isHidden = true
        }
        view.show()
    }
    @objc public static func presentSync() {
        if let current, !current.prepareClose() { current.afterClose = { presentSync() }; return }
        current?.panel.close()
        let view = TDBSharedAccountPanel(sync: true); current = view; view.show()
    }
    // Construct inactive panels only: no helpers, accounts or Keychain access.
    @objc public static func runInterfaceSelfTests() -> Bool {
        guard Thread.isMainThread else { return false }
        let signIn = TDBSharedAccountPanel(sync: false)
        let sharing = TDBSharedAccountPanel(sync: true)
        defer { signIn.panel.close(); sharing.panel.close() }
        func frame(_ view: NSView, in content: NSView) -> NSRect {
            view.superview!.convert(view.alignmentRect(forFrame: view.frame), to: content)
        }
        func footerFits(_ view: TDBSharedAccountPanel, content: NSView) -> Bool {
            let footer = frame(view.footer, in: content)
            guard abs(footer.minY - 24) < 1, abs(footer.height - 32) < 1,
                  footer.minX >= 23, footer.maxX <= content.bounds.maxX - 23 else { return false }
            let buttons = view.footer.arrangedSubviews.compactMap { $0 as? NSButton }.filter { !$0.isHiddenOrHasHiddenAncestor }
            for (index, button) in buttons.enumerated() {
                let rect = frame(button, in: content)
                guard content.bounds.contains(rect), rect.minY >= footer.minY - 1, rect.maxY <= footer.maxY + 1 else { return false }
                for other in buttons.dropFirst(index + 1) where rect.intersects(frame(other, in: content)) { return false }
            }
            return true
        }
        for width in [600.0, 640.0, 900.0] {
            signIn.panel.setContentSize(NSSize(width: width, height: 520))
            guard let content = signIn.panel.contentView else { return false }
            signIn.cancelButton.isHidden = false
            signIn.status.stringValue = "Synthetic sign-in guidance stays above the actions and never expands the footer."
            content.layoutSubtreeIfNeeded()
            guard footerFits(signIn, content: content), let fields = signIn.organizationFields else { return false }
            let disclosure = frame(signIn.organizationToggle, in: content)
            guard abs(disclosure.minX - 24) < 1, disclosure.width < width - 160,
                  signIn.organizationToggle.title == "Organization (optional)", fields.isHidden else { return false }
            let top = signIn.panel.frame.maxY
            signIn.toggleOrganization(); content.layoutSubtreeIfNeeded()
            guard !fields.isHidden, signIn.organizationToggle.state == .on,
                  signIn.organizationToggle.title == "Organization (optional)", abs(signIn.panel.frame.maxY - top) < 1,
                  footerFits(signIn, content: content) else { return false }
            let controls = [signIn.email, signIn.name, signIn.organization, signIn.organizationToggle, signIn.status]
            for (index, control) in controls.enumerated() {
                let rect = frame(control, in: content)
                guard content.bounds.contains(rect), !rect.intersects(frame(signIn.footer, in: content)) else { return false }
                for other in controls.dropFirst(index + 1) where rect.intersects(frame(other, in: content)) { return false }
            }
            for field in [signIn.email, signIn.name, signIn.organization] {
                let rect = frame(field, in: content)
                guard field.isEditable, rect.width >= width - 52, rect.height >= 22 else { return false }
            }
            signIn.toggleOrganization(); content.layoutSubtreeIfNeeded()
            guard fields.isHidden, signIn.organizationToggle.state == .off,
                  abs(signIn.panel.frame.maxY - top) < 1, footerFits(signIn, content: content) else { return false }
            sharing.panel.setContentSize(NSSize(width: width, height: 480))
            guard let sharingContent = sharing.panel.contentView else { return false }
            sharingContent.layoutSubtreeIfNeeded()
            let before = sharing.syncScroll.frame.height
            guard footerFits(sharing, content: sharingContent), before >= 220 else { return false }
            sharing.panel.setContentSize(NSSize(width: width, height: 640)); sharingContent.layoutSubtreeIfNeeded()
            guard footerFits(sharing, content: sharingContent), sharing.syncScroll.frame.height >= before + 159 else { return false }
        }
        return true
    }
    private init(sync: Bool) {
        syncing = sync
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: sync ? 480 : 520),
                        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        panel.title = "Claude Accounts — " + PeerProtocol.displayName(Host.current().localizedName ?? "This Mac")
        panel.isReleasedWhenClosed = false; panel.delegate = self
        let title = NSTextField(labelWithString: sync ? "Claude Sharing" : "Claude Sign-In")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: sync
            ? "Choose which paired Macs may use shared Claude accounts, including accounts received from your other approved Macs. Approval is required on both Macs."
            : "Sign in through Claude Code in your browser on This Mac. Shared access follows your per-Mac approvals.")
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, detail]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12; stack.distribution = .fill
        if !sync {
            for (caption, field) in [("Sign-in email", email), ("Account name (optional)", name), ("Organization (optional, for subscriptions using one email)", organization)] {
                field.placeholderString = caption; field.setAccessibilityLabel(caption)
                let label = NSTextField(labelWithString: caption)
                label.font = .systemFont(ofSize: 13)
                field.heightAnchor.constraint(equalToConstant: 26).isActive = true
                let fields = NSStackView(views: [label, field]); fields.orientation = .vertical; fields.alignment = .leading; fields.spacing = 6
                for view in fields.arrangedSubviews { view.widthAnchor.constraint(equalTo: fields.widthAnchor).isActive = true }
                if field === organization {
                    organizationFields = fields
                    organizationToggle.title = "Organization (optional)"
                    organizationToggle.target = self; organizationToggle.action = #selector(toggleOrganization)
                    organizationToggle.isBordered = false; organizationToggle.setButtonType(.onOff)
                    organizationToggle.font = .systemFont(ofSize: 13); organizationToggle.alignment = .left
                    organizationToggle.imagePosition = .imageLeading; organizationToggle.imageHugsTitle = true
                    organizationToggle.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
                    organizationToggle.setAccessibilityExpanded(false)
                    let row = NSStackView(views: [organizationToggle, NSView()]); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 12
                    row.heightAnchor.constraint(equalToConstant: 26).isActive = true
                    organizationRow = row; stack.addArrangedSubview(row)
                    fields.isHidden = true
                }
                stack.addArrangedSubview(fields)
            }
            let note = NSTextField(wrappingLabelWithString: "Reusable sign-ins last up to one year. Claude.ai connectors need a local sign-in. Running Claude sessions keep their current account.")
            note.font = .systemFont(ofSize: 12); note.textColor = .secondaryLabelColor; stack.addArrangedSubview(note)
            let spacer = NSView()
            spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(rawValue: 1), for: .vertical)
            spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(rawValue: 1), for: .vertical)
            spacer.heightAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
            stack.addArrangedSubview(spacer)
        } else {
            client.agentManagement = true
            syncList.orientation = .vertical; syncList.alignment = .leading; syncList.spacing = 0
            syncList.identifier = .init("AccountSyncMacs")
            syncScroll.documentView = syncList; syncScroll.hasVerticalScroller = true; syncScroll.drawsBackground = false
            syncScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
            syncScroll.setContentHuggingPriority(NSLayoutConstraint.Priority(rawValue: 1), for: .vertical)
            stack.addArrangedSubview(syncScroll)
        }
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 2; status.lineBreakMode = .byWordWrapping
        status.heightAnchor.constraint(greaterThanOrEqualToConstant: 18).isActive = true
        stack.addArrangedSubview(status)
        let done = button("Done", #selector(closePanel)); done.keyEquivalent = "\u{1b}"
        let help = button("About Shared Access", #selector(showHelp)); help.isBordered = false
        var footerViews: [NSView] = [help, NSView()]
        if !sync {
            signInButton.target = self; signInButton.action = #selector(startSignIn); signInButton.keyEquivalent = "\r"
            cancelButton.target = self; cancelButton.action = #selector(cancelSignIn); cancelButton.isHidden = true
            footerViews += [cancelButton, signInButton]
        }
        footerViews.append(done)
        for view in footerViews { footer.addArrangedSubview(view) }
        footer.orientation = .horizontal; footer.alignment = .centerY; footer.spacing = 12
        footer.heightAnchor.constraint(equalToConstant: 32).isActive = true
        footer.setContentHuggingPriority(.required, for: .vertical)
        footer.setContentCompressionResistancePriority(.required, for: .vertical)
        stack.addArrangedSubview(footer)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = panel.contentView!; content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24)])
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        panel.contentMinSize = NSSize(width: 600, height: sync ? 480 : 520)
    }
    private func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
    private func show() {
        panel.center(); panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        client.connect { [weak self] _ in
            guard let self else { return }
            if self.syncing { self.refresh() }
            else {
                self.client.request("accounts.check", payload: [:]) { [weak self] result in
                    if let error = result["error"] as? String { self?.actionError = error; self?.status.stringValue = error }
                    else { self?.refresh() }
                }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }
    private func refresh() {
        guard client.connected else { status.stringValue = "Waiting for this Mac’s background service…"; return }
        if syncing {
            let revision = syncRevision
            client.request("peers.state", payload: [:]) { [weak self] reply in
                guard let self, revision == self.syncRevision else { return }
                self.peerState = reply; self.renderSync()
            }
        } else {
            client.request("accounts.catalog", payload: [:]) { [weak self] reply in
                guard let self else { return }
                let active = reply["signInActive"] as? Bool == true
                self.signInButton.isEnabled = !active; self.cancelButton.isHidden = !active
                if let error = self.actionError ?? reply["error"] as? String { self.status.stringValue = error }
                else { self.status.stringValue = reply["signInPhase"] as? String ?? "" }
            }
        }
    }
    @objc private func startSignIn() {
        let requestedName = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let mail = email.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = requestedName.isEmpty ? String((mail.split(separator: "@").first.map(String.init) ?? "Claude").prefix(40)) : requestedName
        guard mail.contains("@"), !mail.contains(where: \.isWhitespace) else { actionError = "Enter the email you use to sign in."; status.stringValue = actionError!; return }
        let directory = PeerPaths.root.appendingPathComponent("sign-ins/" + UUID().uuidString)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { status.stringValue = "This Mac could not prepare the sign-in."; return }
        var payload: [String: Any] = ["label": label, "email": mail, "organization": organization.stringValue,
                                      "plan": account["plan"] as? String ?? "", "executable": executable, "configDirectory": directory.path]
        if let binding = account["binding"] as? String, !binding.isEmpty { payload["binding"] = binding }
        actionError = nil; signInButton.isEnabled = false; status.stringValue = "Starting Claude Code sign-in in your browser on This Mac…"
        client.request("accounts.signIn.start", payload: payload as NSDictionary) { [weak self] result in
            if let error = result["error"] as? String { self?.actionError = error; self?.status.stringValue = error }
            self?.refresh()
        }
    }
    private func renderSync() {
        let peers = peerState["peers"] as? [[String: Any]] ?? []
        let enabled = syncDraft ?? Set(peerState["accountPeers"] as? [String] ?? [])
        let states = peerState["accountStatus"] as? [String: String] ?? [:]
        let ids = Set(peers.compactMap { $0["id"] as? String })
        for id in Array(syncRows.keys) where !ids.contains(id) {
            if let row = syncRows.removeValue(forKey: id) { syncList.removeArrangedSubview(row); row.removeFromSuperview() }
            choices.removeAll { $0.0 == id }; syncDetails.removeValue(forKey: id)
        }
        for peer in peers {
            guard let id = peer["id"] as? String, let name = peer["name"] as? String else { continue }
            let choice: NSButton, detail: NSTextField
            if let existing = choices.first(where: { $0.0 == id })?.1, let existingDetail = syncDetails[id] { choice = existing; detail = existingDetail }
            else {
                choice = NSButton(checkboxWithTitle: name, target: self, action: #selector(syncChanged(_:)))
                detail = NSTextField(wrappingLabelWithString: ""); detail.font = .systemFont(ofSize: 12); detail.textColor = .secondaryLabelColor
                let row = NSStackView(views: [choice, NSView(), detail]); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 12
                row.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
                syncList.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: syncScroll.contentView.widthAnchor, constant: -12).isActive = true
                choices.append((id, choice)); syncDetails[id] = detail; syncRows[id] = row
                choice.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                detail.widthAnchor.constraint(lessThanOrEqualTo: row.widthAnchor, multiplier: 0.46).isActive = true
            }
            choice.title = name; choice.state = enabled.contains(id) ? .on : .off
            detail.stringValue = enabled.contains(id) ? states[id] ?? "Waiting for the other Mac" : "Sharing off"
        }
        syncList.frame = NSRect(x: 0, y: 0, width: syncScroll.contentSize.width, height: syncList.fittingSize.height)
        if let actionError { status.stringValue = actionError }
        else if peers.isEmpty { status.stringValue = "Pair another Mac from Workstations → Add Mac first." }
        else { status.stringValue = syncSaving ? "Saving sharing settings…" : "Changes save automatically. Enable Claude sharing on the other Mac too." }
    }
    @objc private func syncChanged(_ sender: NSButton) {
        guard let id = choices.first(where: { $0.1 === sender })?.0 else { return }
        var desired = syncDraft ?? Set(peerState["accountPeers"] as? [String] ?? [])
        if sender.state == .on { desired.insert(id) } else { desired.remove(id) }
        syncDraft = desired; syncRevision += 1; actionError = nil
        saveSync(); renderSync()
    }
    private func saveSync() {
        guard !syncSaving, let desired = syncDraft else { return }
        syncSaving = true
        client.request("accounts.sync.configure", payload: ["peers": Array(desired).sorted()]) { [weak self] result in
            guard let self else { return }
            self.syncSaving = false
            if let error = result["error"] as? String {
                self.actionError = error; self.syncDraft = nil; self.closeAfterSync = false; self.afterClose = nil
            } else {
                self.peerState = result
                if self.syncDraft != desired { self.saveSync(); return }
                self.syncDraft = nil
                if self.closeAfterSync { self.panel.close(); return }
            }
            self.renderSync(); self.refresh()
        }
    }
    @objc private func cancelSignIn() { client.request("accounts.signIn.cancel", payload: [:]) { [weak self] result in self?.actionError = result["error"] as? String; self?.refresh() } }
    @objc private func toggleOrganization() {
        let show = organizationFields?.isHidden == true
        organizationFields?.isHidden = !show
        organizationToggle.state = show ? .on : .off
        organizationToggle.image = NSImage(systemSymbolName: show ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        organizationToggle.setAccessibilityExpanded(show)
    }
    @objc private func showHelp() {
        let alert = NSAlert(); alert.messageText = "Shared Claude Access"
        alert.informativeText = "Selected Macs exchange shared accounts over your LAN or VPN. Accounts added while away sync when you reconnect. Pairing alone never enables account sharing.\n\nSharing includes accounts received from other approved Macs. Disabling it stops future transfers; it does not revoke sign-ins already copied. Reusable sign-ins last up to one year."
        alert.addButton(withTitle: "Done"); alert.beginSheetModal(for: panel)
    }
    private func prepareClose() -> Bool {
        guard !syncSaving, syncDraft == nil else { closeAfterSync = true; status.stringValue = "Saving sharing settings…"; return false }
        return true
    }
    public func windowShouldClose(_ sender: NSWindow) -> Bool { prepareClose() }
    @objc private func closePanel() { if prepareClose() { panel.close() } }
    public func windowWillClose(_ notification: Notification) {
        timer?.invalidate(); timer = nil; client.close()
        if Self.current === self { Self.current = nil }
        let next = afterClose; afterClose = nil; next?()
    }
}
