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
    private var catalog: [String: Any] = [:]
    private var peerState: [String: Any] = [:]
    private var pending = false
    private var syncDraft: Set<String>?
    private var syncSaving = false
    private var closeAfterSync = false
    private var actionError: String?
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
        do {
            func object(_ profile: AWSProfileDescriptor) throws -> [String: Any] {
                try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as! [String: Any]
            }
            let engineering = AWSProfileDescriptor(name: "engineering", kind: "sso", ssoStartURL: "https://example.awsapps.com/start", ssoRegion: "us-east-1", accountID: "111111111111", roleName: "Developer")
            let production = AWSProfileDescriptor(name: "production", kind: "sso", ssoStartURL: "https://example.awsapps.com/start", ssoRegion: "us-east-1", accountID: "222222222222", roleName: "ReadOnly")
            let team = AWSProfileDescriptor(name: String(repeating: "team-", count: 16), kind: "sso", ssoStartURL: "https://another.awsapps.com/start", ssoRegion: "us-east-1", accountID: "333333333333", roleName: String(repeating: "LongRole", count: 20))
            let view = TDBAWSAccessPanel()
            defer { view.panel.close() }
            view.catalog = ["profiles": try [object(engineering), object(production)],
                            "configuredProfileIDs": [engineering.id, production.id], "sources": [production.id],
                            "accounts": [["profileId": production.id, "descriptor": try object(production), "available": true, "expires": Date().addingTimeInterval(3600).timeIntervalSince1970],
                                         ["profileId": team.id, "descriptor": try object(team), "available": true, "expires": Date().addingTimeInterval(3600).timeIntervalSince1970]],
                            "installed": [], "sourceStatus": [:], "signInProfile": "",
                            "authentication": [engineering.id: ["state": "missing", "sessionName": "workspace-sso"],
                                               production.id: ["state": "expired", "sessionName": "workspace-sso", "expiresAt": Date().addingTimeInterval(-3600).timeIntervalSince1970]]]
            view.panel.contentView?.layoutSubtreeIfNeeded(); view.render()
            var checks = 0
            for width in [600.0, 700.0, 1000.0] {
                view.panel.setContentSize(NSSize(width: width, height: 560))
                guard let content = view.panel.contentView else { return false }
                content.layoutSubtreeIfNeeded(); view.list.layoutSubtreeIfNeeded()
                let rows = view.list.arrangedSubviews.filter { $0.identifier?.rawValue == "aws-profile-row" }
                guard rows.count == 3 else { return false }
                let clip = view.scroll.contentView.convert(view.scroll.contentView.bounds, to: content)
                let document = view.list.convert(view.list.bounds, to: content)
                var actionX: CGFloat?
                for row in rows {
                    func child(_ identifier: String) -> NSView? { row.subviews.first { $0.identifier?.rawValue == identifier } }
                    guard let title = child("aws-profile-name") as? NSTextField,
                          let identity = child("aws-profile-identity") as? NSTextField,
                          let state = child("aws-profile-state") as? NSTextField,
                          let action = child("aws-profile-primary"), let more = child("aws-profile-actions") else { return false }
                    func rect(_ item: NSView) -> NSRect { item.superview!.convert(item.alignmentRect(forFrame: item.frame), to: content) }
                    let nameRect = rect(title), identityRect = rect(identity), stateRect = rect(state), actionRect = rect(action), moreRect = rect(more)
                    let conditions = [nameRect.width >= 150, nameRect.height >= 16,
                                      identityRect.width >= 150, identityRect.height >= 14, stateRect.height >= 14,
                                      !nameRect.intersects(identityRect), !identityRect.intersects(stateRect),
                                      nameRect.maxX <= actionRect.minX - 8, stateRect.maxX <= actionRect.minX - 8,
                                      actionRect.maxX <= moreRect.minX - 8, moreRect.maxX <= clip.maxX + 1,
                                      nameRect.minX >= clip.minX - 1, moreRect.maxX <= document.maxX + 1,
                                      title.font?.pointSize == 14, identity.maximumNumberOfLines == 1, state.maximumNumberOfLines == 1,
                                      identity.toolTip == identity.stringValue, !title.isHidden,
                                      actionX.map { abs($0 - actionRect.minX) < 1 } ?? true]
                    guard conditions.allSatisfy({ $0 }) else { fputs("AWS profile row layout regression failed.\n", stderr); return false }
                    checks += conditions.count; actionX = actionRect.minX
                    if let authentication = child("aws-profile-authentication") as? NSTextField {
                        let authenticationRect = rect(authentication)
                        let authenticationLayout = [!identityRect.intersects(authenticationRect), !authenticationRect.intersects(stateRect),
                                                    authenticationRect.maxX <= actionRect.minX - 8,
                                                    authentication.maximumNumberOfLines == 1, authenticationRect.height >= 14,
                                                    !authentication.isHidden, !(authentication.toolTip ?? "").isEmpty]
                        guard authenticationLayout.allSatisfy({ $0 }) else { fputs("AWS SSO status layout regression failed.\n", stderr); return false }
                        checks += authenticationLayout.count
                    }
                }
            }
            let engineeringRow = view.list.arrangedSubviews.first { row in
                row.subviews.contains { ($0 as? NSTextField)?.stringValue == "engineering" }
            }
            guard let signIn = engineeringRow?.subviews.first(where: { $0.identifier?.rawValue == "aws-profile-primary" }) as? NSButton else { return false }
            var requested: [(String, [String: Any])] = []
            view.requestForTesting = { requested.append(($0, $1)) }
            // Presentation IDs must never replace the callback's routing key.
            // Exercise the actual NSButton target/action, not the closure itself.
            signIn.identifier = .init("aws-profile-primary")
            signIn.performClick(nil)
            let routing = [requested.count == 1, requested.first?.0 == "aws.signIn.start", requested.first?.1["profileId"] as? String == engineering.id]
            guard routing.allSatisfy({ $0 }) else { fputs("AWS profile action routing regression failed.\n", stderr); return false }
            checks += routing.count
            func profileRow(_ name: String) -> NSView? {
                view.list.arrangedSubviews.first { row in row.subviews.contains { ($0 as? NSTextField)?.stringValue == name } }
            }
            func field(_ row: NSView?, _ identifier: String) -> NSTextField? {
                row?.subviews.first { $0.identifier?.rawValue == identifier } as? NSTextField
            }
            func primary(_ row: NSView?) -> NSButton? {
                row?.subviews.first { $0.identifier?.rawValue == "aws-profile-primary" } as? NSButton
            }
            let expiredRow = profileRow("production")
            let expired = [primary(expiredRow)?.title == "Sign In", primary(expiredRow)?.isEnabled == true,
                           field(expiredRow, "aws-profile-authentication")?.stringValue == "SSO needs renewal · workspace-sso",
                           field(expiredRow, "aws-profile-state")?.stringValue.hasPrefix("Cached access until ") == true,
                           field(expiredRow, "aws-profile-authentication")?.textColor == .systemOrange]
            guard expired.allSatisfy({ $0 }) else { fputs("AWS cached-access SSO expiry regression failed.\n", stderr); return false }
            checks += expired.count
            primary(expiredRow)?.performClick(nil)
            let cachedRouting = [requested.count == 2, requested.last?.0 == "aws.signIn.start", requested.last?.1["profileId"] as? String == production.id]
            guard cachedRouting.allSatisfy({ $0 }) else { return false }; checks += cachedRouting.count

            view.catalog["signInProfile"] = production.id
            view.catalog["signInProfiles"] = [engineering.id, production.id]
            view.render()
            for name in ["engineering", "production"] {
                let row = profileRow(name)
                let grouped = [primary(row)?.title == "Signing In…", primary(row)?.isEnabled == false,
                               field(row, "aws-profile-authentication")?.stringValue == "Signing in to SSO…"]
                guard grouped.allSatisfy({ $0 }) else { return false }; checks += grouped.count
            }
            // Cancellation keeps cached credentials visible and immediately
            // restores the session-renewal action instead of a Ready badge.
            view.catalog["signInProfile"] = ""; view.catalog["signInProfiles"] = []
            view.render()
            let cancelled = [primary(profileRow("production"))?.title == "Sign In", primary(profileRow("production"))?.isEnabled == true,
                             field(profileRow("production"), "aws-profile-state")?.stringValue.hasPrefix("Cached access until ") == true]
            guard cancelled.allSatisfy({ $0 }) else { return false }; checks += cancelled.count
            view.catalog["authentication"] = [production.id: ["state": "current", "sessionName": "workspace-sso", "expiresAt": Date().addingTimeInterval(3600).timeIntervalSince1970],
                                              engineering.id: ["state": "current", "sessionName": "workspace-sso", "expiresAt": Date().addingTimeInterval(3600).timeIntervalSince1970]]
            view.render()
            let current = [primary(profileRow("production"))?.title == "Sign In Again",
                           field(profileRow("production"), "aws-profile-authentication")?.stringValue == "SSO signed in · workspace-sso",
                           field(profileRow("production"), "aws-profile-state")?.stringValue.hasPrefix("Cached access until ") == true]
            guard current.allSatisfy({ $0 }) else { return false }; checks += current.count
            // A shared SSO login authenticates unshared sibling profiles too.
            // Missing role-cache material must not make the UI claim sign-in
            // is required again while the shared session is current.
            let sibling = profileRow("engineering")
            let unshared = [primary(sibling)?.title == "Sign In Again", primary(sibling)?.isEnabled == true,
                            field(sibling, "aws-profile-authentication")?.stringValue == "SSO signed in · workspace-sso",
                            field(sibling, "aws-profile-state")?.stringValue == "Not shared"]
            guard unshared.allSatisfy({ $0 }) else { return false }; checks += unshared.count
            primary(sibling)?.performClick(nil)
            let siblingRouting = [requested.count == 3, requested.last?.0 == "aws.signIn.start", requested.last?.1["profileId"] as? String == engineering.id]
            guard siblingRouting.allSatisfy({ $0 }) else { return false }; checks += siblingRouting.count
            view.catalog["authentication"] = [production.id: ["state": "unrecognized-future-state"]]
            view.render()
            let unknown = [primary(profileRow("production"))?.title == "Sign In",
                           field(profileRow("production"), "aws-profile-authentication")?.stringValue == "SSO status unavailable"]
            guard unknown.allSatisfy({ $0 }) else { return false }; checks += unknown.count
            view.catalog["installed"] = [["profileId": team.id, "descriptor": try object(team), "targetName": "received-team"]]
            view.catalog["authentication"] = [team.id: ["state": "missing"]]
            view.render()
            let receiver = profileRow("received-team")
            let receiving = [primary(receiver)?.title == "Sign In", primary(receiver)?.isEnabled == true,
                             field(receiver, "aws-profile-authentication")?.stringValue == "SSO sign-in available on This Mac",
                             field(receiver, "aws-profile-authentication")?.textColor == .secondaryLabelColor,
                             field(receiver, "aws-profile-state")?.stringValue.hasPrefix("Cached access until ") == true]
            guard receiving.allSatisfy({ $0 }) else { return false }; checks += receiving.count
            print("AWS interface layout checks passed: \(checks)")
            return true
        } catch { fputs("AWS interface layout fixtures could not be prepared.\n", stderr); return false }
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
    private func signInButton(_ title: String, profile: String) -> NSButton {
        let value = button(title) { [weak self] in self?.request("aws.signIn.start", ["profileId": profile]) }
        value.isEnabled = value.isEnabled && (catalog["signInProfile"] as? String ?? "").isEmpty
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
            body = ["profiles": catalog["profiles"] ?? [], "configuredProfileIDs": catalog["configuredProfileIDs"] ?? [], "accounts": catalog["accounts"] ?? [],
                    "installed": catalog["installed"] ?? [], "sourceStatus": catalog["sourceStatus"] ?? [:],
                    "sources": catalog["sources"] ?? [], "signIn": catalog["signInProfile"] ?? "",
                    "signInProfiles": catalog["signInProfiles"] ?? [], "authentication": catalog["authentication"] ?? [:]]
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
            addRow(NSStackView(views: [label("Pair another Mac from TerminalDB → Workstations → Add Mac first.")]))
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

    private func renderProfiles() {
        profileRows = AWSProfilePresentation.rows(catalog: catalog)
        let sources = Set(catalog["sources"] as? [String] ?? [])
        let states = catalog["sourceStatus"] as? [String: String] ?? [:]
        var signingIn = Set(catalog["signInProfiles"] as? [String] ?? [])
        if let selected = catalog["signInProfile"] as? String, !selected.isEmpty { signingIn.insert(selected) }
        if profileRows.isEmpty {
            addRow(NSStackView(views: [label("No supported AWS profiles yet. Configure an SSO or console-login profile with the AWS CLI, or choose Sharing to receive profiles from your Macs.")]))
            return
        }
        for item in profileRows {
            let id = item.id, source = sources.contains(item.id)
            let title = NSTextField(labelWithString: item.name)
            title.font = .systemFont(ofSize: 14, weight: .semibold); title.lineBreakMode = .byTruncatingMiddle
            title.identifier = .init("aws-profile-name")
            title.setAccessibilityIdentifier("aws-profile-name")
            var availability = states[id] ?? (item.hasLocalProfile && !source ? "Not shared" : item.status)
            let showsAuthentication = item.descriptor.kind == "sso" && (item.hasLocalProfile || item.isInstalled || source)
            let optionalLocalSignIn = item.isInstalled && !item.hasLocalProfile && !source && item.available && item.authentication.state == "missing"
            let needsRenewal = states[id] == "Sign in on this Mac to renew" || (showsAuthentication && item.authentication.needsRenewal)
            if let expires = item.expiration, item.available {
                let time = DateFormatter.localizedString(from: Date(timeIntervalSince1970: expires), dateStyle: .none, timeStyle: .short)
                availability = (showsAuthentication ? "Cached access until " : (source || item.isInstalled ? "Access until " : "Shared access until ")) + time
            }
            let identity = NSTextField(labelWithString: item.identitySummary)
            let state = NSTextField(labelWithString: availability)
            let authenticationText = optionalLocalSignIn ? "SSO sign-in available on This Mac" : item.authentication.label
            let authentication = NSTextField(labelWithString: signingIn.contains(id) ? "Signing in to SSO…" : authenticationText)
            authentication.identifier = .init("aws-profile-authentication")
            authentication.setAccessibilityIdentifier("aws-profile-authentication")
            authentication.font = .systemFont(ofSize: 12)
            authentication.textColor = needsRenewal && !optionalLocalSignIn && !signingIn.contains(id) ? .systemOrange : .secondaryLabelColor
            for label in [title, identity, authentication, state] {
                label.lineBreakMode = .byTruncatingMiddle
                label.maximumNumberOfLines = 1
                label.toolTip = label.stringValue
                label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            }
            for label in [identity, state] { label.font = .systemFont(ofSize: 12); label.textColor = .secondaryLabelColor }
            authentication.lineBreakMode = .byTruncatingTail
            if let expiry = item.authentication.expiration {
                authentication.toolTip = item.authentication.label + "\nSSO token expiry: " + DateFormatter.localizedString(from: Date(timeIntervalSince1970: expiry), dateStyle: .short, timeStyle: .short)
            }
            identity.identifier = .init("aws-profile-identity"); state.identifier = .init("aws-profile-state")
            let primary: NSView
            if item.status == "Choose Account Again" {
                primary = button("Review…") { [weak self] in self?.showDetails(item) }
            } else if signingIn.contains(id) {
                primary = signInButton("Signing In…", profile: id)
            } else if item.hasLocalProfile || item.isInstalled || source {
                let signedIn = showsAuthentication ? item.authentication.state == "current" : (item.available && !needsRenewal)
                primary = signInButton(signedIn ? "Sign In Again" : "Sign In", profile: id)
            } else {
                primary = button("Use on This Mac…") { [weak self] in self?.install(item) }
            }
            primary.identifier = .init("aws-profile-primary")
            let menu = NSMenu(); menu.autoenablesItems = false; menu.delegate = self
            if !source && item.hasLocalProfile {
                addMenuItem("Share Current Sign-In", to: menu) { [weak self] in self?.request("aws.source.enable", ["profileId": id]) }
            }
            if !item.isInstalled && item.available && ((item.hasLocalProfile && !source) || (!item.hasLocalProfile && source)) {
                addMenuItem(source ? "Use on This Mac…" : "Use Shared Access on This Mac…", to: menu) { [weak self] in self?.install(item) }
            }
            if source { addMenuItem("Refresh Access", to: menu) { [weak self] in self?.request("aws.refresh", ["profileId": id]) } }
            else { addMenuItem("Sync Now", to: menu) { [weak self] in self?.syncNow() } }
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
            let children: [NSView] = [title, identity] + (showsAuthentication ? [authentication] : []) + [state, primary, more, divider]
            for child in children { child.translatesAutoresizingMaskIntoConstraints = false; row.addSubview(child) }
            list.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor, constant: -12), row.heightAnchor.constraint(equalToConstant: showsAuthentication ? 100 : 80),
                more.trailingAnchor.constraint(equalTo: row.trailingAnchor), more.widthAnchor.constraint(equalToConstant: 32),
                more.heightAnchor.constraint(equalToConstant: 28), more.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                primary.trailingAnchor.constraint(equalTo: more.leadingAnchor, constant: -12), primary.widthAnchor.constraint(equalToConstant: 128),
                primary.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                title.leadingAnchor.constraint(equalTo: row.leadingAnchor), title.trailingAnchor.constraint(equalTo: primary.leadingAnchor, constant: -12),
                title.topAnchor.constraint(equalTo: row.topAnchor, constant: 12), title.heightAnchor.constraint(equalToConstant: 18),
                identity.leadingAnchor.constraint(equalTo: title.leadingAnchor), identity.trailingAnchor.constraint(equalTo: title.trailingAnchor),
                identity.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3), identity.heightAnchor.constraint(equalToConstant: 16),
                state.leadingAnchor.constraint(equalTo: title.leadingAnchor), state.trailingAnchor.constraint(equalTo: title.trailingAnchor),
                state.topAnchor.constraint(equalTo: showsAuthentication ? authentication.bottomAnchor : identity.bottomAnchor, constant: 3), state.heightAnchor.constraint(equalToConstant: 16),
                divider.leadingAnchor.constraint(equalTo: row.leadingAnchor), divider.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                divider.bottomAnchor.constraint(equalTo: row.bottomAnchor), divider.heightAnchor.constraint(equalToConstant: 1)
            ])
            if showsAuthentication {
                NSLayoutConstraint.activate([
                    authentication.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                    authentication.trailingAnchor.constraint(equalTo: title.trailingAnchor),
                    authentication.topAnchor.constraint(equalTo: identity.bottomAnchor, constant: 3),
                    authentication.heightAnchor.constraint(equalToConstant: 16)
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
        if item.descriptor.kind == "sso" { lines.append(item.authentication.label) }
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
    private func install(_ item: AWSProfilePresentation, suggestedName: String? = nil) {
        let name = item.name, suggested = suggestedName ?? item.suggestedName(rows: profileRows, occupiedNames: Set(catalog["localProfileNames"] as? [String] ?? []))
        let alert = NSAlert()
        alert.messageText = "Use \(name) on This Mac?"
        let context: String
        if suggestedName != nil {
            context = "Add another name for this AWS access. Existing names stay available."
        } else if item.hasLocalProfile {
            context = "TerminalDB will back up this profile’s settings and manage its sign-ins. Renew access with Sign In here. Choose a new name to keep the original profile separate."
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
