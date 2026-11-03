import AppKit

private final class AWSAccessList: NSStackView {
    override var isFlipped: Bool { true }
}

@objc(TDBAWSAccessPanel)
public final class TDBAWSAccessPanel: NSObject, NSWindowDelegate, NSMenuDelegate {
    private static var current: TDBAWSAccessPanel?
    private let panel: NSPanel
    private let host = TDBSessionClient()
    private let agent = TDBSessionClient()
    private let list = AWSAccessList()
    private let scroll = NSScrollView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let subtitle = NSTextField(wrappingLabelWithString: "")
    private let tabs = NSSegmentedControl(labels: ["Profiles", "Sharing"], trackingMode: .selectOne, target: nil, action: nil)
    private let cancel = NSButton(title: "Cancel Sign-In", target: nil, action: nil)
    private var timer: Timer?
    private var rowsSignature = ""
    private var choices: [(String, NSButton)] = []
    private var actions: [String: () -> Void] = [:]
    private var buttonActions: [ObjectIdentifier: () -> Void] = [:]
    private var requestForTesting: ((String, [String: Any]) -> Void)?
    private var confirmInstallForTesting: ((String, String) -> Void)?
    private var syncForTesting: (() -> Void)?
    private var catalog: [String: Any] = [:]
    private var peerState: [String: Any] = [:]
    private var pending = false
    private var syncDraft: Set<String>?
    private var syncSaving = false
    private var closeAfterSync = false
    private var actionError: String?
    private var lastPhase: String?
    private var profileRows: [AWSProfilePresentation] = []
    private var trackingMenu = false

    @objc public static func present() {
        if let current { current.panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let view = TDBAWSAccessPanel(); current = view; view.show()
    }

    // AppKit geometry is exercised after NSApplication initializes, without
    // presenting a window, connecting a helper, or loading real account data.
    @objc public static func runInterfaceSelfTests() -> Bool {
        guard Thread.isMainThread else { return false }
        var checks = 0
        do {
            func check(_ condition: Bool, _ detail: String) throws {
                guard condition else { throw PeerFailure("AWS interface: " + detail) }; checks += 1
            }
            func object(_ profile: AWSProfileDescriptor) throws -> [String: Any] {
                try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as! [String: Any]
            }
            func profile(_ name: String, _ account: String, role: String = "Developer") -> AWSProfileDescriptor {
                .init(name: name, kind: "sso", ssoStartURL: "https://example.awsapps.com/start", ssoRegion: "us-east-1", accountID: account, roleName: role, ssoSessionName: "workspace-sso")
            }
            let engineering = profile("engineering", "111111111111")
            let production = profile("production", "222222222222")
            let incoming = profile(String(repeating: "team-", count: 16), "333333333333", role: String(repeating: "LongRole", count: 20))
            let matchingNative = profile("native-match", "444444444444")
            let migrated = profile("migrated", "555555555555")
            let offline = profile("offline", "666666666666")
            let conflict = profile("conflict", "777777777777")
            let collision = profile("occupied", "888888888888")
            let expiration = Date().addingTimeInterval(3600).timeIntervalSince1970
            func account(_ descriptor: AWSProfileDescriptor, available: Bool = true, status: String = "Ready") throws -> [String: Any] {
                ["profileId": descriptor.id, "descriptor": try object(descriptor), "available": available, "status": status,
                 "expires": expiration, "sourceNames": ["Fixture Mac"]]
            }
            let base: [String: Any] = [
                "profiles": try [object(engineering), object(production), object(matchingNative), object(migrated)],
                "configuredProfileIDs": [engineering.id, production.id, matchingNative.id, migrated.id],
                "localProfileNames": ["engineering", "production", "native-match", "migrated", "occupied"],
                "sources": [production.id],
                "accounts": try [account(production), account(incoming), account(matchingNative), account(migrated),
                                  account(offline, available: false, status: "Expired"), account(conflict, available: false, status: "Choose Account Again"), account(collision)],
                "installed": [["profileId": migrated.id, "descriptor": try object(migrated), "targetName": "migrated"],
                              ["profileId": offline.id, "descriptor": try object(offline), "targetName": "offline"]],
                "sourceStatus": [:], "signInProfile": "", "signInProfiles": [],
                "authentication": [engineering.id: ["state": "current", "sessionName": "workspace-sso", "expiresAt": expiration],
                                   production.id: ["state": "expired", "sessionName": "workspace-sso", "expiresAt": expiration - 7200],
                                   matchingNative.id: ["state": "expired", "sessionName": "workspace-sso"],
                                   migrated.id: ["state": "expired", "sessionName": "workspace-sso"]]
            ]
            let view = TDBAWSAccessPanel(); defer { view.panel.close() }
            view.catalog = base; view.peerState = ["awsPeers": ["fixture-peer"]]
            view.panel.contentView?.layoutSubtreeIfNeeded(); view.render()
            func descendant(_ root: NSView, _ identifier: String) -> NSView? {
                if root.identifier?.rawValue == identifier { return root }
                for child in root.subviews { if let value = descendant(child, identifier) { return value } }
                return nil
            }
            func row(_ name: String) throws -> NSView {
                guard let value = view.list.arrangedSubviews.first(where: { item in
                    (descendant(item, "aws-profile-name") as? NSTextField)?.stringValue == name
                }) else { throw PeerFailure("AWS interface: missing fixture row") }
                return value
            }
            func control(_ name: String, _ identifier: String = "aws-profile-primary") throws -> NSView {
                guard let value = descendant(try row(name), identifier) else { throw PeerFailure("AWS interface: missing fixture control") }
                return value
            }
            func field(_ name: String, _ identifier: String) throws -> NSTextField {
                guard let value = try control(name, identifier) as? NSTextField else { throw PeerFailure("AWS interface: missing fixture text") }
                return value
            }
            func click(_ name: String, secondary: Bool = false) throws {
                guard let value = try control(name, secondary ? "aws-profile-secondary" : "aws-profile-primary") as? NSButton else {
                    throw PeerFailure("AWS interface: action is not a button")
                }
                value.performClick(nil)
            }
            for width in [600.0, 700.0, 1000.0] {
                view.panel.setContentSize(NSSize(width: width, height: 560))
                guard let content = view.panel.contentView else { return false }
                content.layoutSubtreeIfNeeded(); view.list.layoutSubtreeIfNeeded()
                let rows = view.list.arrangedSubviews.filter { $0.identifier?.rawValue == "aws-profile-row" }
                try check(rows.count == 8, "fixture row count")
                let clip = view.scroll.contentView.convert(view.scroll.contentView.bounds, to: content)
                let document = view.list.convert(view.list.bounds, to: content)
                var columnX: CGFloat?
                for row in rows {
                    guard let title = descendant(row, "aws-profile-name") as? NSTextField,
                          let identity = descendant(row, "aws-profile-identity") as? NSTextField,
                          let state = descendant(row, "aws-profile-state") as? NSTextField,
                          let primary = descendant(row, "aws-profile-primary"), let more = descendant(row, "aws-profile-actions") else { return false }
                    func rect(_ item: NSView) -> NSRect { item.superview!.convert(item.alignmentRect(forFrame: item.frame), to: content) }
                    let nameRect = rect(title), identityRect = rect(identity), stateRect = rect(state), actionRect = rect(primary), moreRect = rect(more)
                    for condition in [nameRect.width >= 150, nameRect.height >= 16,
                                      identityRect.width >= 150, identityRect.height >= 14, stateRect.height >= 14,
                                      !nameRect.intersects(identityRect), !identityRect.intersects(stateRect),
                                      nameRect.maxX <= actionRect.minX - 8, stateRect.maxX <= actionRect.minX - 8,
                                      actionRect.maxX <= moreRect.minX - 8, moreRect.maxX <= clip.maxX + 1,
                                      nameRect.minX >= clip.minX - 1, moreRect.maxX <= document.maxX + 1,
                                      title.font?.pointSize == 14, identity.maximumNumberOfLines == 1, state.maximumNumberOfLines == 1,
                                      identity.toolTip == identity.stringValue, !title.isHidden,
                                      columnX.map { abs($0 - actionRect.minX) < 1 } ?? true] {
                        try check(condition, "row geometry at width \(width)")
                    }
                    columnX = actionRect.minX
                    if let authentication = descendant(row, "aws-profile-authentication") as? NSTextField {
                        let authRect = rect(authentication)
                        for condition in [!identityRect.intersects(authRect), !authRect.intersects(stateRect), authRect.maxX <= actionRect.minX - 8,
                                          authentication.maximumNumberOfLines == 1, authRect.height >= 14, !authentication.isHidden,
                                          !(authentication.toolTip ?? "").isEmpty] { try check(condition, "authentication geometry") }
                    }
                    if let secondary = descendant(row, "aws-profile-secondary") {
                        let secondaryRect = rect(secondary)
                        for condition in [!secondaryRect.intersects(actionRect), abs(secondaryRect.minX - actionRect.minX) < 1,
                                          abs(secondaryRect.width - actionRect.width) < 1, stateRect.maxX <= secondaryRect.minX - 8,
                                          secondaryRect.height >= 14] { try check(condition, "secondary action geometry") }
                    }
                }
            }
            var requested: [(String, [String: Any])] = [], confirmations: [(String, String)] = []
            var syncRequests = 0
            view.requestForTesting = { requested.append(($0, $1)) }
            view.confirmInstallForTesting = { confirmations.append(($0, $1)) }
            view.syncForTesting = { syncRequests += 1 }
            // Exercise real target/action dispatch. Identifiers label controls;
            // they must not replace the persistent profile routing key.
            try check((try control("engineering") as? NSButton)?.title == "Share Access", "share is the direct local action")
            try check((try control("engineering", "aws-profile-actions") as? NSButton)?.menu?.items.contains { $0.title == "Share This Mac’s Access" } == false, "visible share is not duplicated in the menu")
            try click("engineering")
            try check(requested.last?.0 == "aws.source.enable" && requested.last?.1["profileId"] as? String == engineering.id, "share routing")
            try click("engineering", secondary: true)
            try check(requested.last?.0 == "aws.signIn.start" && requested.last?.1["profileId"] as? String == engineering.id, "secondary sign-in routing")
            try check((try control("production") as? NSButton)?.title == "Sign In", "expired source sign-in")
            try check(try field("production", "aws-profile-authentication").stringValue == "SSO needs renewal", "short session status")
            try check(try field("production", "aws-profile-authentication").toolTip?.contains("workspace-sso") == true, "session stays in tooltip")
            try click("production")
            try check(requested.last?.0 == "aws.signIn.start" && requested.last?.1["profileId"] as? String == production.id, "source sign-in routing")
            try click("production", secondary: true)
            try check(requested.last?.0 == "aws.refresh" && requested.last?.1["profileId"] as? String == production.id, "secondary refresh routing")
            try check((try control(incoming.name) as? NSButton)?.title == "Use on This Mac", "one-click import label")
            try check((try control("native-match") as? NSButton)?.title == "Use on This Mac…", "native migration label indicates confirmation")
            try check((try control("occupied") as? NSButton)?.title == "Use on This Mac…", "collision label indicates confirmation")
            try click(incoming.name)
            try check(requested.last?.0 == "aws.use" && requested.last?.1["profileId"] as? String == incoming.id && requested.last?.1["targetName"] as? String == incoming.name && requested.last?.1["replaceSource"] as? Bool == false, "fresh use is one click")
            try check(confirmations.isEmpty, "fresh import avoids a redundant modal")
            let requestCount = requested.count
            try click("native-match")
            try check(requested.count == requestCount && confirmations.last?.0 == matchingNative.id && confirmations.last?.1 == "native-match", "native migration requires confirmation")
            try click("occupied")
            try check(requested.count == requestCount && confirmations.last?.0 == collision.id && confirmations.last?.1 != "occupied", "name collision requires alias confirmation")
            try check((try control("offline") as? NSButton)?.title == "Sync Now", "unavailable receiver sync action")
            try click("offline")
            try check(syncRequests == 1, "sync routing")
            try check((try control("offline", "aws-profile-secondary") as? NSButton)?.title == "Sign In Here", "visible local fallback")
            try click("offline", secondary: true)
            try check(requested.last?.0 == "aws.signIn.start" && requested.last?.1["profileId"] as? String == offline.id, "fallback sign-in routing")
            try check((try control("conflict") as? NSButton)?.title == "Review…", "conflict review action")

            // An installed receiver remains ready even when retained native
            // SSO metadata is expired, missing or unreadable. Shared access is
            // its active provider; optional local sign-in belongs in the menu.
            for status in ["expired", "missing", "unknown", "current"] {
                view.catalog["authentication"] = [migrated.id: ["state": status, "sessionName": "workspace-sso"]]
                view.render()
                let ready = try control("migrated")
                try check(!(ready is NSButton), "ready is not a sign-in button")
                try check((ready as? NSTextField)?.stringValue == "Ready on This Mac", "receiver ready label")
                try check(try field("migrated", "aws-profile-authentication").stringValue == "From Fixture Mac", "receiver origin")
                try check(try field("migrated", "aws-profile-authentication").textColor == .secondaryLabelColor, "receiver has no SSO warning")
                let more = try control("migrated", "aws-profile-actions") as? NSButton
                try check(more?.menu?.items.contains { $0.title == "Sign In Here…" } == true, "optional sign-in remains available")
            }
            guard let readyMenu = (try control("migrated", "aws-profile-actions") as? NSButton)?.menu,
                  let shareIndex = readyMenu.items.firstIndex(where: { $0.title == "Share This Mac’s Access" }) else { return false }
            let beforeReuse = requested.count
            readyMenu.performActionForItem(at: shareIndex)
            try check(requested.count == beforeReuse + 1 && requested.last?.0 == "aws.source.enable" && requested.last?.1["profileId"] as? String == migrated.id, "ready receiver can share its native sign-in through the advanced menu")
            view.catalog = base; view.catalog["signInProfile"] = production.id
            view.catalog["signInProfiles"] = [engineering.id, production.id]; view.render()
            for name in ["engineering", "production"] {
                let signingIn = try control(name)
                try check(!(signingIn is NSButton) && (signingIn as? NSTextField)?.stringValue == "Signing In…", "shared sign-in progress")
            }
            view.catalog = base; view.catalog["sourceStatus"] = [production.id: "Renewing…"]; view.render()
            let refreshing = try control("production")
            try check(!(refreshing is NSButton) && (refreshing as? NSTextField)?.stringValue == "Refreshing…", "source refresh progress")
            view.catalog = base; view.peerState = ["awsPeers": []]; view.render()
            func allSubviews(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(allSubviews) }
            guard let choose = allSubviews(view.list).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Choose Macs" }) else { return false }
            choose.performClick(nil)
            try check(view.tabs.selectedSegment == 1, "source setup opens Sharing")
            view.catalog = [:]; view.tabs.selectedSegment = 0; view.render()
            guard let setup = allSubviews(view.list).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Set Up Sharing" }) else { return false }
            setup.performClick(nil)
            try check(view.tabs.selectedSegment == 1, "empty setup opens Sharing")

            // Catalog phase is persistent service history. A completed old
            // sign-in must not replace feedback for a newer Sync or Sharing
            // action; active progress and newly completed sign-ins still show.
            let completed = "SSO session signed in. Its profiles can renew access on this Mac."
            let progress = "Complete AWS sign-in in your browser."
            let checking = "Checking your approved Macs for updated access…"
            view.lastPhase = nil; view.status.stringValue = ""; view.pending = false; view.actionError = nil
            view.applyCatalogStatus(["phase": completed])
            try check(view.status.stringValue.isEmpty, "initial historical sign-in completion is hidden")
            view.status.stringValue = checking
            view.applyCatalogStatus(["phase": completed])
            try check(view.status.stringValue == checking, "historical completion preserves sync feedback")
            view.applyCatalogStatus(["phase": progress, "signInProfile": engineering.id])
            try check(view.status.stringValue == progress, "active sign-in progress is visible")
            view.status.stringValue = checking
            view.applyCatalogStatus(["phase": progress, "signInProfile": engineering.id])
            try check(view.status.stringValue == progress, "active sign-in remains visible without phase changes")
            view.applyCatalogStatus(["phase": completed])
            try check(view.status.stringValue == completed, "new completion is visible")
            view.status.stringValue = "Sharing preferences saved."
            view.applyCatalogStatus(["phase": completed])
            try check(view.status.stringValue == "Sharing preferences saved.", "historical completion preserves sharing feedback")
            view.pending = true; view.status.stringValue = "Updating AWS access…"
            view.applyCatalogStatus(["phase": progress, "signInProfile": engineering.id])
            try check(view.status.stringValue == "Updating AWS access…" && view.lastPhase == completed, "pending action preserves feedback without consuming phase transition")
            view.pending = false
            view.applyCatalogStatus(["phase": progress, "signInProfile": engineering.id])
            try check(view.status.stringValue == progress, "phase transition displays after pending action")
            view.actionError = "Could not sync approved Macs."
            view.applyCatalogStatus(["phase": completed])
            try check(view.status.stringValue == view.actionError, "action error takes precedence over service history")
            view.actionError = nil; view.status.stringValue = "Waiting for this Mac’s background service…"
            view.applyCatalogStatus(["phase": completed])
            try check(view.status.stringValue.isEmpty, "connected catalog clears connection wait feedback")
            print("AWS interface layout checks passed: \(checks)")
            return true
        } catch {
            let detail = (error as? PeerFailure)?.message ?? "fixtures could not be prepared"
            FileHandle.standardError.write(Data(("AWS interface regression failed: " + detail + "\n").utf8))
            return false
        }
    }

    private override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 700, height: 560),
                        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        panel.title = "AWS Access — " + PeerProtocol.displayName(Host.current().localizedName ?? "This Mac")
        panel.isReleasedWhenClosed = false; panel.delegate = self
        let title = NSTextField(labelWithString: "AWS Profiles")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        subtitle.textColor = .secondaryLabelColor
        tabs.selectedSegment = 0; tabs.target = self; tabs.action = #selector(changeTab)
        tabs.setAccessibilityLabel("AWS access view")
        list.orientation = .vertical; list.alignment = .leading; list.spacing = 0
        list.identifier = .init("AWSProfiles")
        list.autoresizingMask = [.width]
        scroll.documentView = list; scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        let help = NSButton(title: "About Shared Access", target: self, action: #selector(showHelp)); help.isBordered = false
        let done = NSButton(title: "Done", target: self, action: #selector(closePanel)); done.keyEquivalent = "\u{1b}"
        cancel.target = self; cancel.action = #selector(cancelSignIn); cancel.isHidden = true
        let footer = NSStackView(views: [help, NSView(), cancel, done]); footer.orientation = .horizontal; footer.spacing = 12
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        status.setAccessibilityLabel("AWS access status")
        let stack = NSStackView(views: [title, subtitle, tabs, scroll, status, footer])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = panel.contentView!; content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22)
        ])
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        panel.minSize = NSSize(width: 600, height: 520)
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
        view.font = .systemFont(ofSize: 12)
        return view
    }

    private func updateSubtitle() {
        subtitle.stringValue = tabs.selectedSegment == 0
            ? "Manage profiles for commands on This Mac. Existing profiles are detected automatically."
            : "Choose which paired Macs may exchange selected AWS access. Approval is required on both Macs."
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
                self.applyCatalogStatus(self.catalog)
                self.render()
            }
        } else { status.stringValue = "Waiting for this Mac’s background service…" }
        if agent.connected {
            agent.request("peers.state", payload: [:]) { [weak self] result in
                self?.peerState = result as? [String: Any] ?? [:]; self?.render()
            }
        }
    }

    private func applyCatalogStatus(_ result: [String: Any]) {
        let phase = result["phase"] as? String ?? ""
        let changed = lastPhase.map { $0 != phase } ?? false
        let signingIn = !(result["signInProfile"] as? String ?? "").isEmpty
        if !pending { lastPhase = phase }
        if let error = actionError { status.stringValue = error }
        else if !pending && !phase.isEmpty && (signingIn || changed) { status.stringValue = phase }
        else if status.stringValue == "Waiting for this Mac’s background service…" { status.stringValue = "" }
    }

    private func clearRows() {
        for view in list.arrangedSubviews { list.removeArrangedSubview(view); view.removeFromSuperview() }
        actions.removeAll(); buttonActions.removeAll(); choices.removeAll()
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
        buttonActions[ObjectIdentifier(value)] = action
        value.isEnabled = !pending
        return value
    }
    @objc private func invokeAction(_ sender: NSButton) {
        buttonActions[ObjectIdentifier(sender)]?()
    }

    private func render() {
        guard !trackingMenu else { return }
        let syncing = tabs.selectedSegment == 1
        var body: [String: Any]
        if syncing {
            let enabled = syncDraft.map { Array($0).sorted() } ?? (peerState["awsPeers"] as? [String] ?? [])
            body = ["peers": peerState["peers"] ?? [], "enabled": enabled,
                    "connected": agent.connected, "states": peerState["awsStatus"] ?? [:]]
        } else {
            body = ["profiles": catalog["profiles"] ?? [], "configuredProfileIDs": catalog["configuredProfileIDs"] ?? [], "localProfileNames": catalog["localProfileNames"] ?? [], "accounts": catalog["accounts"] ?? [],
                    "installed": catalog["installed"] ?? [], "sourceStatus": catalog["sourceStatus"] ?? [:],
                    "sources": catalog["sources"] ?? [], "signIn": catalog["signInProfile"] ?? "",
                    "signInProfiles": catalog["signInProfiles"] ?? [], "authentication": catalog["authentication"] ?? [:],
                    "awsPeers": peerState["awsPeers"] ?? []]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return }
        let signature = "\(syncing):\(pending):" + String(decoding: data, as: UTF8.self)
        guard signature != rowsSignature else { return }
        let position = scroll.contentView.bounds.origin
        rowsSignature = signature; clearRows()
        if syncing { renderMacs() } else { renderProfiles() }
        list.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: list.fittingSize.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(position.y, max(0, list.frame.height - scroll.contentSize.height))))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func renderMacs() {
        guard agent.connected else {
            addRow(NSStackView(views: [label("Waiting for this Mac’s networking. Check any macOS Keychain or background-app permission prompt, then try again.")]))
            return
        }
        let peers = peerState["peers"] as? [[String: Any]] ?? []
        let enabled = syncDraft ?? Set(peerState["awsPeers"] as? [String] ?? [])
        let states = peerState["awsStatus"] as? [String: String] ?? [:]
        if peers.isEmpty {
            addRow(NSStackView(views: [label("Pair a Mac in TerminalDB → Workstations, then choose it here.")]))
        }
        for peer in peers {
            guard let id = peer["id"] as? String, let name = peer["name"] as? String else { continue }
            let choice = NSButton(checkboxWithTitle: name, target: self, action: #selector(syncMacChanged(_:)))
            choice.state = enabled.contains(id) ? .on : .off
            choices.append((id, choice))
            let detail = label(enabled.contains(id) ? states[id] ?? "Waiting for the other Mac" : "Sharing off")
            let row = NSStackView(views: [choice, NSView(), detail]); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 12
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
            detail.widthAnchor.constraint(lessThanOrEqualTo: row.widthAnchor, multiplier: 0.46).isActive = true
            choice.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addRow(NSStackView(views: [row]))
        }
        addRow(NSStackView(views: [label("Sharing includes profiles received from your other approved Macs. Changes save automatically.", small: true)]))
    }

    private func profileActionView(_ action: AWSProfileRowAction, item: AWSProfilePresentation, secondary: Bool) -> NSView {
        switch action {
        case .ready, .signingIn, .refreshing:
            let value = NSTextField(labelWithString: action.title)
            value.font = .systemFont(ofSize: 12, weight: action == .ready ? .semibold : .regular)
            value.textColor = action == .ready ? .labelColor : .secondaryLabelColor
            value.alignment = .center
            value.setAccessibilityLabel(action == .ready ? "Ready on This Mac" : action.title)
            return value
        default:
            let title: String
            if action == .useSharedAccess {
                title = action.title + (canInstallImmediately(item) ? "" : "…")
            } else {
                title = secondary && action == .signIn ? "Sign In Here" : action.title
            }
            let value = button(title) { [weak self] in self?.performProfileAction(action, item: item) }
            value.setAccessibilityLabel(title + " for " + item.name)
            if action == .signIn || action == .signInAgain {
                value.isEnabled = value.isEnabled && (catalog["signInProfile"] as? String ?? "").isEmpty
            }
            return value
        }
    }

    private func performProfileAction(_ action: AWSProfileRowAction, item: AWSProfilePresentation) {
        switch action {
        case .signIn, .signInAgain: request("aws.signIn.start", ["profileId": item.id])
        case .shareAccess: request("aws.source.enable", ["profileId": item.id])
        case .useSharedAccess: install(item)
        case .syncNow: syncNow()
        case .refreshAccess: request("aws.refresh", ["profileId": item.id])
        case .review: showDetails(item)
        case .ready, .signingIn, .refreshing: break
        }
    }

    private func sharingSetupRow(_ copy: String, buttonTitle: String) -> NSStackView {
        let text = label(copy)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let setup = button(buttonTitle) { [weak self] in
            guard let self else { return }; self.tabs.selectedSegment = 1; self.changeTab()
        }
        setup.setAccessibilityLabel(buttonTitle + " for AWS sharing")
        setup.widthAnchor.constraint(equalToConstant: 140).isActive = true
        let line = NSStackView(views: [text, setup])
        line.orientation = .horizontal; line.alignment = .centerY; line.spacing = 12
        line.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
        return NSStackView(views: [line])
    }

    private func renderProfiles() {
        profileRows = AWSProfilePresentation.rows(catalog: catalog)
        let sources = Set(catalog["sources"] as? [String] ?? [])
        let states = catalog["sourceStatus"] as? [String: String] ?? [:]
        var signingIn = Set(catalog["signInProfiles"] as? [String] ?? [])
        if let selected = catalog["signInProfile"] as? String, !selected.isEmpty { signingIn.insert(selected) }
        if profileRows.isEmpty {
            addRow(sharingSetupRow("Receive AWS access from another Mac in Sharing. Profiles you already use with the AWS CLI appear here automatically.", buttonTitle: "Set Up Sharing"))
            return
        }
        if !sources.isEmpty && (peerState["awsPeers"] as? [String] ?? []).isEmpty {
            addRow(sharingSetupRow("Choose which Macs receive the profiles you share.", buttonTitle: "Choose Macs"))
        }
        for item in profileRows {
            let id = item.id, source = sources.contains(item.id)
            let presentation = item.rowState(isSource: source, sourceStatus: states[id], isSigningIn: signingIn.contains(id))
            let title = NSTextField(labelWithString: item.name)
            title.font = .systemFont(ofSize: 14, weight: .semibold)
            title.identifier = .init("aws-profile-name"); title.setAccessibilityIdentifier("aws-profile-name")
            let identity = NSTextField(labelWithString: item.identitySummary)
            let authentication = NSTextField(labelWithString: presentation.authenticationText)
            authentication.identifier = .init("aws-profile-authentication"); authentication.setAccessibilityIdentifier("aws-profile-authentication")
            authentication.font = .systemFont(ofSize: 12)
            authentication.textColor = presentation.needsAttention ? .systemOrange : .secondaryLabelColor
            let state = NSTextField(labelWithString: presentation.availabilityText)
            identity.identifier = .init("aws-profile-identity"); state.identifier = .init("aws-profile-state")
            for field in [title, identity, authentication, state] {
                field.lineBreakMode = .byTruncatingMiddle; field.maximumNumberOfLines = 1
                field.toolTip = field.stringValue
                field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            }
            for field in [identity, state] { field.font = .systemFont(ofSize: 12); field.textColor = .secondaryLabelColor }
            authentication.lineBreakMode = .byTruncatingTail
            authentication.toolTip = presentation.authenticationTooltip
            let actionColumn = NSStackView(); actionColumn.orientation = .vertical; actionColumn.alignment = .centerX; actionColumn.spacing = 4
            actionColumn.identifier = .init("aws-profile-action-column")
            actionColumn.setHuggingPriority(.required, for: .vertical)
            let visibleActions = [presentation.primaryAction, presentation.secondaryAction].compactMap { $0 }
            for (index, action) in visibleActions.enumerated() {
                let view = profileActionView(action, item: item, secondary: index == 1)
                view.identifier = .init(index == 0 ? "aws-profile-primary" : "aws-profile-secondary")
                view.translatesAutoresizingMaskIntoConstraints = false
                actionColumn.addArrangedSubview(view)
                view.widthAnchor.constraint(equalTo: actionColumn.widthAnchor).isActive = true
                view.heightAnchor.constraint(equalToConstant: view is NSButton ? 28 : 16).isActive = true
            }
            let menu = NSMenu(); menu.autoenablesItems = false; menu.delegate = self
            if !visibleActions.contains(.signIn) && !visibleActions.contains(.signInAgain) && (item.isInstalled || item.hasLocalProfile || source) {
                addMenuItem("Sign In Here…", to: menu, enabled: (catalog["signInProfile"] as? String ?? "").isEmpty) { [weak self] in self?.request("aws.signIn.start", ["profileId": id]) }
            }
            if !source && item.hasLocalProfile && !visibleActions.contains(.shareAccess) {
                addMenuItem("Share This Mac’s Access", to: menu) { [weak self] in self?.request("aws.source.enable", ["profileId": id]) }
            }
            if source && !visibleActions.contains(.refreshAccess) { addMenuItem("Refresh Access", to: menu) { [weak self] in self?.request("aws.refresh", ["profileId": id]) } }
            else if !source && !visibleActions.contains(.syncNow) { addMenuItem("Sync Now", to: menu) { [weak self] in self?.syncNow() } }
            if item.isInstalled {
                addMenuItem("Use Another Profile Name…", to: menu) { [weak self] in
                    guard let self else { return }
                    let rows = AWSProfilePresentation.rows(catalog: self.catalog)
                    let current = rows.first { $0.id == id } ?? item
                    let suggested = current.suggestedAdditionalName(rows: rows, occupiedNames: Set(self.catalog["localProfileNames"] as? [String] ?? []))
                    self.install(current, suggestedName: suggested)
                }
            }
            addMenuItem("Profile Details…", to: menu) { [weak self] in self?.showDetails(item) }
            if source || item.isInstalled {
                menu.addItem(.separator())
                addMenuItem("Remove from This Mac…", to: menu) { [weak self] in self?.remove(id: id, name: item.name) }
            }
            let more = NSButton(image: NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Profile actions") ?? NSImage(), target: self, action: #selector(showActions(_:)))
            more.isBordered = false; more.menu = menu; more.isEnabled = !pending
            more.identifier = .init("aws-profile-actions"); more.setAccessibilityLabel("Actions for \(item.name)")
            more.toolTip = "Profile actions"
            let row = NSView(); row.identifier = .init("aws-profile-row"); row.translatesAutoresizingMaskIntoConstraints = false
            let divider = NSBox(); divider.boxType = .separator
            let children: [NSView] = [title, identity] + (presentation.showsAuthentication ? [authentication] : []) + [state, actionColumn, more, divider]
            for child in children { child.translatesAutoresizingMaskIntoConstraints = false; row.addSubview(child) }
            list.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor, constant: -12),
                row.heightAnchor.constraint(equalToConstant: presentation.showsAuthentication || presentation.secondaryAction != nil ? 100 : 80),
                more.trailingAnchor.constraint(equalTo: row.trailingAnchor), more.widthAnchor.constraint(equalToConstant: 32),
                more.heightAnchor.constraint(equalToConstant: 28), more.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                actionColumn.trailingAnchor.constraint(equalTo: more.leadingAnchor, constant: -12), actionColumn.widthAnchor.constraint(equalToConstant: 140),
                actionColumn.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                title.leadingAnchor.constraint(equalTo: row.leadingAnchor), title.trailingAnchor.constraint(equalTo: actionColumn.leadingAnchor, constant: -12),
                title.topAnchor.constraint(equalTo: row.topAnchor, constant: 12), title.heightAnchor.constraint(equalToConstant: 18),
                identity.leadingAnchor.constraint(equalTo: title.leadingAnchor), identity.trailingAnchor.constraint(equalTo: title.trailingAnchor),
                identity.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3), identity.heightAnchor.constraint(equalToConstant: 16),
                state.leadingAnchor.constraint(equalTo: title.leadingAnchor), state.trailingAnchor.constraint(equalTo: title.trailingAnchor),
                state.topAnchor.constraint(equalTo: presentation.showsAuthentication ? authentication.bottomAnchor : identity.bottomAnchor, constant: 3), state.heightAnchor.constraint(equalToConstant: 16),
                divider.leadingAnchor.constraint(equalTo: row.leadingAnchor), divider.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                divider.bottomAnchor.constraint(equalTo: row.bottomAnchor), divider.heightAnchor.constraint(equalToConstant: 1)
            ])
            if presentation.showsAuthentication {
                NSLayoutConstraint.activate([
                    authentication.leadingAnchor.constraint(equalTo: title.leadingAnchor), authentication.trailingAnchor.constraint(equalTo: title.trailingAnchor),
                    authentication.topAnchor.constraint(equalTo: identity.bottomAnchor, constant: 3), authentication.heightAnchor.constraint(equalToConstant: 16)
                ])
            }
        }
        addRow(NSStackView(views: [label("Profiles in the same SSO session share one sign-in.")]))
    }

    private func addMenuItem(_ title: String, to menu: NSMenu, enabled: Bool = true, action: @escaping () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(invokeMenuAction(_:)), keyEquivalent: "")
        let id = UUID().uuidString; item.representedObject = id; item.target = self; actions[id] = action
        item.isEnabled = enabled && !pending
        menu.addItem(item)
    }
    @objc private func showActions(_ sender: NSButton) { sender.menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender) }
    public func menuWillOpen(_ menu: NSMenu) { trackingMenu = true }
    public func menuDidClose(_ menu: NSMenu) { trackingMenu = false; DispatchQueue.main.async { [weak self] in self?.render() } }
    @objc private func invokeMenuAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }; actions[id]?()
    }
    private func showDetails(_ item: AWSProfilePresentation) {
        let alert = NSAlert(); alert.messageText = item.name
        var lines = [item.identitySummary]
        if item.descriptor.kind == "sso" {
            let isSource = (catalog["sources"] as? [String] ?? []).contains(item.id)
            let prefix = !isSource && (item.isInstalled || item.available) ? "Local sign-in (optional): " : "Local sign-in: "
            lines.append(prefix + item.authentication.label)
        }
        if !item.localNames.isEmpty { lines.append("Local names: " + item.localNames.joined(separator: ", ")) }
        if !item.installedNames.isEmpty { lines.append("Managed names: " + item.installedNames.joined(separator: ", ")) }
        let otherNames = item.sharedNames.filter { !item.localNames.contains($0) && !item.installedNames.contains($0) }
        if !otherNames.isEmpty { lines.append("Names on other Macs: " + otherNames.joined(separator: ", ")) }
        if !item.sourceNames.isEmpty { lines.append("Provided by: " + item.sourceNames.joined(separator: ", ")) }
        if item.status == "Choose Account Again" { lines.append("Different sign-ins are providing conflicting identities. Sign in with the intended account and stop sharing the older identity before using this profile. TerminalDB will not choose credentials silently.") }
        lines.append("Matching AWS identities share one row. Local profile names are preserved; identical names alone do not identify an account.")
        alert.informativeText = lines.joined(separator: "\n\n"); alert.addButton(withTitle: "Done")
        alert.beginSheetModal(for: panel)
    }
    @objc private func showHelp() {
        let alert = NSAlert(); alert.messageText = "Shared AWS Access"
        alert.informativeText = "Only selected profiles are shared with explicitly approved Macs. Browser sign-ins remain on their original Mac; each receiver keeps temporary access until AWS’s expiry.\n\nOne SSO sign-in renews all profiles using that same session on This Mac. Only profiles you choose are shared.\n\nYou can sign in on any Mac. Profiles shared while away arrive automatically after LAN or VPN reconnects. Disabling sharing stops future transfers; revoke access in AWS when immediate termination is required. Claude sharing is configured separately."
        alert.addButton(withTitle: "Done"); alert.beginSheetModal(for: panel)
    }
    private func canInstallImmediately(_ item: AWSProfilePresentation, suggestedName: String? = nil) -> Bool {
        let occupied = Set(catalog["localProfileNames"] as? [String] ?? [])
        let suggested = suggestedName ?? item.suggestedName(rows: profileRows, occupiedNames: occupied)
        return suggestedName == nil && !item.hasLocalProfile && !item.isInstalled && suggested == item.descriptor.name && !occupied.contains(suggested)
    }
    private func install(_ item: AWSProfilePresentation, suggestedName: String? = nil) {
        let name = item.name, suggested = suggestedName ?? item.suggestedName(rows: profileRows, occupiedNames: Set(catalog["localProfileNames"] as? [String] ?? []))
        if canInstallImmediately(item, suggestedName: suggestedName) {
            request("aws.use", ["profileId": item.id, "targetName": suggested, "replaceSource": false])
            return
        }
        if let confirmInstallForTesting { confirmInstallForTesting(item.id, suggested); return }
        let alert = NSAlert()
        alert.messageText = "Use \(name) on This Mac?"
        let context: String
        if suggestedName != nil {
            context = "Add another name for this AWS access. Existing names stay available."
        } else if item.hasLocalProfile {
            context = "TerminalDB will back up this profile’s settings and use shared access from your approved Macs. Choose a new name to keep the original profile separate."
        } else if suggested != item.descriptor.name {
            context = "A different profile already uses that name. Use the suggested name to keep both."
        } else {
            context = "This profile will use shared access from your approved Macs."
        }
        alert.informativeText = context + "\n\nUse this name with --profile in AWS commands."
        let field = NSTextField(string: suggested); field.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
        field.setAccessibilityLabel("AWS profile name on This Mac"); alert.accessoryView = field
        alert.addButton(withTitle: "Use Profile"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: panel) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.request("aws.use", ["profileId": item.id, "targetName": field.stringValue, "replaceSource": item.localNames.contains(field.stringValue)])
        }
    }

    private func remove(id: String, name: String) {
        let alert = NSAlert(); alert.messageText = "Remove \(name) from TerminalDB on This Mac?"
        alert.informativeText = "This stops sharing this AWS access from This Mac and removes its TerminalDB-managed profile aliases. Their original settings are restored when safe. Other AWS profiles stay unchanged. Temporary credentials already copied to other Macs remain valid until AWS expires or revokes them."
        alert.addButton(withTitle: "Remove Profile"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: panel) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.request("aws.remove", ["profileId": id]) }
        }
    }

    private func request(_ operation: String, _ payload: [String: Any]) {
        if let requestForTesting { requestForTesting(operation, payload); return }
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
                self.status.stringValue = "Sharing preferences saved."
                if self.closeAfterSync { self.panel.close(); return }
            }
            self.rowsSignature = ""
            self.refresh()
        }
    }
    private func syncNow() {
        if let syncForTesting { syncForTesting(); return }
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
