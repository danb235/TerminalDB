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
    private var organizationCaption: NSTextField?
    private let status = NSTextField(wrappingLabelWithString: "")
    private var timer: Timer?
    private var choices: [(String, NSButton)] = []
    private var syncDetails: [String: NSTextField] = [:]
    private var executable = ""
    private var account: [String: Any] = [:]
    private var syncing = false

    @objc(presentSignIn:executable:)
    public static func presentSignIn(_ account: NSDictionary, executable: String) {
        current?.panel.close()
        let view = TDBSharedAccountPanel(sync: false)
        current = view; view.account = account as? [String: Any] ?? [:]; view.executable = executable
        view.name.stringValue = view.account["label"] as? String ?? ""
        view.email.stringValue = view.account["email"] as? String ?? ""
        view.organization.stringValue = view.account["organization"] as? String ?? ""
        if !view.organization.stringValue.isEmpty {
            view.organization.isHidden = true; view.organizationCaption?.isHidden = true
        }
        view.show()
    }
    @objc public static func presentSync() {
        current?.panel.close()
        let view = TDBSharedAccountPanel(sync: true); current = view; view.show()
    }
    private init(sync: Bool) {
        syncing = sync
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 570, height: sync ? 520 : 440),
                        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        panel.title = sync ? "Sync Claude accounts" : "Sign in once for your Macs"
        panel.isReleasedWhenClosed = false; panel.delegate = self
        let title = NSTextField(labelWithString: sync ? "Your accounts, on your Macs" : "Use this account across your Macs")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: sync
            ? "Selected Macs exchange shared accounts over your LAN or VPN. Accounts added while away sync automatically when you reconnect. Enable account sync on both Macs."
            : "Claude Code opens its own sign-in page in your browser on This Mac. Choose the email below. TerminalDB saves its reusable sign-in in Keychain; passwords never enter TerminalDB.")
        detail.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, detail]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        if !sync {
            for (caption, field) in [("Account name", name), ("Email used to sign in", email), ("Organization (optional, for multiple subscriptions using one email)", organization)] {
                field.placeholderString = caption; field.setAccessibilityLabel(caption)
                let label = NSTextField(labelWithString: caption)
                if field === organization { organizationCaption = label }
                stack.addArrangedSubview(label); stack.addArrangedSubview(field)
            }
            let note = NSTextField(wrappingLabelWithString: "Reusable sign-ins last up to one year. Claude.ai connectors need a local sign-in. Running Claude sessions keep their current account.")
            note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor; stack.addArrangedSubview(note)
            stack.addArrangedSubview(button("Sign In in Browser", #selector(startSignIn)))
            stack.addArrangedSubview(button("Cancel Sign-In", #selector(cancelSignIn)))
        } else {
            client.agentManagement = true
            let list = SharedAccountList(); list.orientation = .vertical; list.alignment = .leading; list.spacing = 8
            list.identifier = .init("AccountSyncMacs")
            let scroll = NSScrollView(); scroll.documentView = list; scroll.hasVerticalScroller = true
            scroll.heightAnchor.constraint(equalToConstant: 220).isActive = true
            stack.addArrangedSubview(scroll)
            let notice = NSTextField(wrappingLabelWithString: "This shares accounts added here and accounts received from other synced Macs. Adding a Mac to sync gives it access to those accounts. Pairing a new Mac does not add it automatically. Turning sync off stops future transfers; it does not revoke credentials already copied.")
            notice.font = .systemFont(ofSize: 11); notice.textColor = .secondaryLabelColor; stack.addArrangedSubview(notice)
            stack.addArrangedSubview(button("Save Sync Settings", #selector(saveSync)))
        }
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor; stack.addArrangedSubview(status)
        let done = button("Done", #selector(closePanel)); done.keyEquivalent = "\u{1b}"
        stack.addArrangedSubview(done)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = panel.contentView!; content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22), stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22), stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -22)])
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        panel.minSize = NSSize(width: 570, height: sync ? 520 : 590)
        if !sync { panel.setContentSize(NSSize(width: 570, height: 590)) }
    }
    private func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
    private func show() {
        panel.center(); panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        client.connect { [weak self] _ in
            guard let self else { return }
            if self.syncing { self.refresh() }
            else {
                self.client.request("accounts.check", payload: [:]) { [weak self] result in
                    if let error = result["error"] as? String { self?.status.stringValue = error }
                    else { self?.refresh() }
                }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }
    private func refresh() {
        guard client.connected else { status.stringValue = "Waiting for this Mac’s background service…"; return }
        if syncing {
            client.request("peers.state", payload: [:]) { [weak self] reply in
                guard let self else { return }
                if let scroll = self.panel.contentView?.subviews.first?.subviews.compactMap({ $0 as? NSScrollView }).first,
                   let list = scroll.documentView as? NSStackView {
                    let enabled = Set(reply["accountPeers"] as? [String] ?? [])
                    let states = reply["accountStatus"] as? [String: String] ?? [:]
                    for peer in reply["peers"] as? [[String: Any]] ?? [] {
                        guard let id = peer["id"] as? String, let name = peer["name"] as? String else { continue }
                        if let detail = self.syncDetails[id] { detail.stringValue = states[id] ?? "Not synced yet"; continue }
                        let choice = NSButton(checkboxWithTitle: name, target: nil, action: nil)
                        choice.state = enabled.contains(id) ? .on : .off
                        list.addArrangedSubview(choice); self.choices.append((id, choice))
                        let detail = NSTextField(labelWithString: states[id] ?? "Not synced yet")
                        self.syncDetails[id] = detail
                        detail.textColor = .secondaryLabelColor; list.addArrangedSubview(detail)
                    }
                    list.frame = NSRect(x: 0, y: 0, width: max(480, scroll.bounds.width), height: CGFloat(max(1, self.choices.count)) * 48)
                }
                if self.choices.isEmpty { self.status.stringValue = "Pair another Mac from Workstations → Add Mac first." }
            }
        } else {
            client.request("accounts.catalog", payload: [:]) { [weak self] reply in
                guard let self else { return }
                if let error = reply["error"] as? String { self.status.stringValue = error }
                else if let phase = reply["signInPhase"] as? String, !phase.isEmpty { self.status.stringValue = phase }
            }
        }
    }
    @objc private func startSignIn() {
        let label = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let mail = email.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, mail.contains("@"), !mail.contains(where: \.isWhitespace) else { status.stringValue = "Enter an account name and its sign-in email."; return }
        let directory = PeerPaths.root.appendingPathComponent("sign-ins/" + UUID().uuidString)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { status.stringValue = "This Mac could not prepare the sign-in."; return }
        var payload: [String: Any] = ["label": label, "email": mail, "organization": organization.stringValue,
                                      "plan": account["plan"] as? String ?? "", "executable": executable, "configDirectory": directory.path]
        if let binding = account["binding"] as? String, !binding.isEmpty { payload["binding"] = binding }
        status.stringValue = "Starting Claude Code sign-in in your browser…"
        client.request("accounts.signIn.start", payload: payload as NSDictionary) { [weak self] result in
            if let error = result["error"] as? String { self?.status.stringValue = error }
        }
    }
    @objc private func cancelSignIn() { client.request("accounts.signIn.cancel", payload: [:]) { [weak self] _ in self?.status.stringValue = "Sign-in cancelled." } }
    @objc private func closePanel() { panel.close() }
    @objc private func saveSync() {
        client.request("accounts.sync.configure", payload: ["peers": choices.filter { $0.1.state == .on }.map(\.0)]) { [weak self] result in
            self?.status.stringValue = result["error"] as? String ?? "Saved. Accounts sync automatically when your Macs reconnect."
        }
    }
    public func windowWillClose(_ notification: Notification) { timer?.invalidate(); timer = nil; client.close() }
}
