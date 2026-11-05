import AppKit

private final class AWSAccessList: NSStackView {
    override var isFlipped: Bool { true }
}

@objc(TDBAWSAccessPanel)
public final class TDBAWSAccessPanel: NSObject, NSWindowDelegate, NSMenuDelegate {
    private static var current: TDBAWSAccessPanel?
    // Process-local metadata only: reopening Accounts can observe an auth job
    // this app explicitly started without persisting any authentication material.
    private static var localSignInToResume: String?
    private static var localSignInAttemptToResume: String?
    private static var localSignInUncertainToResume = false
    private static var localSignInAcknowledgedAt: Double?
    private lazy var panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 700, height: 560),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    @objc public let view = NSView()
    @objc public var localSignInHandler: ((NSDictionary) -> Void)? {
        didSet { rowsSignature = ""; detailsSignature = ""; render(); renderDetails() }
    }
    @objc public var statusDidChange: ((NSDictionary) -> Void)?
    private let host: TDBSessionClient
    private let embedded: Bool
    private let isLocalWorkstation: Bool
    private let workstationName: String
    private let workstationIdentifier: String
    private var active = false
    private var lifecycle = 0
    private var statusRequestPending = false
    private var snapshotState = "ready"
    private var snapshotStale = false
    private var allowedRemoteOperations: Set<String> = []
    private var remoteCanManage = false
    private var remoteRequiresControl = false
    private var remoteControlForTesting: Bool?
    private var hostConnectionForTesting: Bool?
    private var snapshotMessage: String?
    private var localAuthClient: TDBSessionClient?
    private var localAuthProfileID: String?
    private var localAuthAttempt: String?
    private var localAuthStarting = false
    private var localAuthObserved = false
    private var localAuthMonitoring = false
    private var localAuthSubmittedAt = 0.0
    private var localAuthWasSubmitted = false
    private var localAuthUncertain = false
    private var localAuthGeneration = 0
    private var localAuthCancelable = false
    private var localAuthStatusPending = false
    private var localAuthRequestForTesting: ((String, NSDictionary, @escaping (NSDictionary) -> Void) -> Void)?
    private let localAuthBanner = NSTextField(wrappingLabelWithString: "")
    private let localAuthCancel = NSButton(title: "Cancel Sign-In", target: nil, action: nil)
    private let localAuthSharing = NSButton(title: "AWS Sharing on This Mac…", target: nil, action: nil)
    private let localAuthSection = NSStackView()
    private var statusRequestForTesting: ((String, @escaping (NSDictionary) -> Void) -> Void)?
    private let sharingButton = NSButton(title: "Sharing…", target: nil, action: nil)
    private let backButton = NSButton(title: "Back to Profiles", target: nil, action: nil)
    private let helpButton = NSButton(title: "About Shared Access", target: nil, action: nil)
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
    private var detailsPanel: NSPanel?
    private var detailsBody: NSStackView?
    private var detailsID: String?
    private var detailsSignature = ""
    private var detailsActions: [ObjectIdentifier: () -> Void] = [:]
    private var suppressDetailsPresentationForTesting = false

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
                "sourceStatus": [:], "sourceChecks": [production.id: ["state": "signInRequired", "checkedAt": expiration - 3600, "expiresAt": expiration]], "signInProfile": "", "signInProfiles": [],
                "authentication": [engineering.id: ["state": "current", "sessionName": "workspace-sso", "expiresAt": expiration],
                                   production.id: ["state": "expired", "sessionName": "workspace-sso", "expiresAt": expiration - 7200],
                                   matchingNative.id: ["state": "expired", "sessionName": "workspace-sso"],
                                   migrated.id: ["state": "expired", "sessionName": "workspace-sso"]]
            ]
            let view = TDBAWSAccessPanel(); view.hostConnectionForTesting = true; defer { view.panel.close() }
            view.suppressDetailsPresentationForTesting = true
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
                          let primary = descendant(row, "aws-profile-primary"), let more = descendant(row, "aws-profile-actions"), let details = descendant(row, "aws-profile-details") else { return false }
                    func rect(_ item: NSView) -> NSRect { item.superview!.convert(item.alignmentRect(forFrame: item.frame), to: content) }
                    let nameRect = rect(title), identityRect = rect(identity), stateRect = rect(state), actionRect = rect(primary), moreRect = rect(more), detailsRect = rect(details)
                    for condition in [nameRect.width >= 150, nameRect.height >= 16,
                                      identityRect.width >= 150, identityRect.height >= 14, stateRect.height >= 14,
                                      !nameRect.intersects(identityRect), !identityRect.intersects(stateRect),
                                      nameRect.maxX <= actionRect.minX - 8, stateRect.maxX <= actionRect.minX - 8,
                                      actionRect.maxX <= detailsRect.minX - 8, detailsRect.maxX <= moreRect.minX - 8, detailsRect.width >= 70, moreRect.maxX <= clip.maxX + 1,
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
            guard let localDetails = try control("engineering", "aws-profile-details") as? NSButton else { return false }
            localDetails.performClick(nil)
            guard let localCheck = descendant(view.detailsPanel!.contentView!, "aws-details-check") as? NSButton else { return false }
            localCheck.performClick(nil)
            try check(requested.last?.0 == "aws.check" && requested.last?.1["profileId"] as? String == engineering.id && requested.last?.1["manual"] as? Bool == true, "local Details check is nonpublishing")
            try check((try control("production") as? NSTextField)?.stringValue == "Ready", "cached access remains ready with confirmed renewal failure")
            try check((try control("production", "aws-profile-secondary") as? NSButton)?.title == "Sign In", "confirmed renewal sign-in is direct")
            try check(!((try field("production", "aws-profile-state")).stringValue.contains("until")), "main row hides credential expiry")
            try click("production", secondary: true)
            try check(requested.last?.0 == "aws.signIn.start" && requested.last?.1["profileId"] as? String == production.id, "confirmed source sign-in routing")
            (try control("production", "aws-profile-details") as? NSButton)?.performClick(nil)
            guard let sourceCheck = descendant(view.detailsPanel!.contentView!, "aws-details-check") as? NSButton else { return false }
            sourceCheck.performClick(nil)
            try check(requested.last?.0 == "aws.refresh" && requested.last?.1["profileId"] as? String == production.id, "source Details check routing")
            try check(descendant(view.detailsPanel!.contentView!, "aws-details-expiry") != nil, "expiry belongs in Details")
            try check((descendant(view.detailsPanel!.contentView!, "aws-details-expiry-help") as? NSTextField)?.stringValue == "Check Access does not reset expiry.", "Details explains the credential clock")
            try check(descendant(view.detailsPanel!.contentView!, "aws-details-sign-in") != nil, "confirmed authentication failure offers sign-in")
            try check(view.detailsBody!.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }.allSatisfy { !$0.contains("SSO") && !$0.contains("token") }, "Details has no cached-token sign-in clock")
            view.applyActionResult("aws.check", result: ["accepted": false]); view.renderDetails()
            try check((descendant(view.detailsPanel!.contentView!, "aws-details-action-error") as? NSTextField)?.stringValue.contains("busy") == true, "manual capacity error is visible inside open Details")
            view.applyActionResult("aws.check", result: ["accepted": true]); view.renderDetails()
            try check(descendant(view.detailsPanel!.contentView!, "aws-details-action-error") == nil && view.status.stringValue.isEmpty, "accepted check clears error without Saved or a permanent checking footer")
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
            try check(descendant(try row("offline"), "aws-profile-secondary") == nil, "receiver never requires a local sign-in")
            (try control("offline", "aws-profile-details") as? NSButton)?.performClick(nil)
            guard let receiverCheck = descendant(view.detailsPanel!.contentView!, "aws-details-check") as? NSButton,
                  let optionalLogin = descendant(view.detailsPanel!.contentView!, "aws-details-sign-in") as? NSButton else { return false }
            receiverCheck.performClick(nil)
            try check(requested.last?.0 == "aws.check" && requested.last?.1["profileId"] as? String == offline.id, "receiver Details performs a real access check")
            optionalLogin.performClick(nil)
            try check(requested.last?.0 == "aws.signIn.start" && requested.last?.1["profileId"] as? String == offline.id, "optional local sign-in stays in Details")
            try check((try control("conflict") as? NSButton)?.title == "Review…", "conflict review action")

            // An installed receiver remains ready even when retained native
            // SSO metadata is expired, missing or unreadable. Shared access is
            // its active provider; optional local sign-in belongs in the menu.
            for status in ["expired", "missing", "unknown", "current"] {
                view.catalog["authentication"] = [migrated.id: ["state": status, "sessionName": "workspace-sso"]]
                view.render()
                let ready = try control("migrated")
                try check(!(ready is NSButton), "ready is not a sign-in button")
                try check((ready as? NSTextField)?.stringValue == "Ready", "receiver ready label")
                try check(try field("migrated", "aws-profile-authentication").stringValue == "From Fixture Mac", "receiver origin")
                try check(try field("migrated", "aws-profile-authentication").textColor == .secondaryLabelColor, "receiver has no SSO warning")
                let more = try control("migrated", "aws-profile-actions") as? NSButton
                try check(more?.menu?.items.contains { $0.title == "Sign In Here…" } == true && more?.menu?.items.contains { $0.title.contains("Refresh") } == false, "optional sign-in remains an advanced menu action")
            }
            guard let readyMenu = (try control("migrated", "aws-profile-actions") as? NSButton)?.menu,
                  let shareIndex = readyMenu.items.firstIndex(where: { $0.title == "Share This Mac’s Access" }) else { return false }
            let beforeReuse = requested.count
            readyMenu.performActionForItem(at: shareIndex)
            try check(requested.count == beforeReuse + 1 && requested.last?.0 == "aws.source.enable" && requested.last?.1["profileId"] as? String == migrated.id, "ready receiver can share its native sign-in through the advanced menu")
            view.catalog = base
            view.catalog["sourceChecks"] = [migrated.id: ["state": "checkFailed", "needsSharedRenewal": true]]
            var missingAccounts = base["accounts"] as! [[String: Any]]
            for index in missingAccounts.indices where missingAccounts[index]["profileId"] as? String == migrated.id { missingAccounts[index]["available"] = false }
            view.catalog["accounts"] = missingAccounts; view.render()
            try check((try control("migrated") as? NSButton)?.title == "Sync Now", "missing receiver credentials retain sync recovery")
            let beforeFreshImport = requested.count
            view.catalog["accounts"] = base["accounts"]; view.render()
            try check((try control("migrated") as? NSTextField)?.stringValue == "Ready" && requested.count == beforeFreshImport, "fresh shared credentials restore Ready without Check Access")
            view.catalog = base; view.catalog["signInProfile"] = production.id
            view.catalog["signInProfiles"] = [engineering.id, production.id]; view.render()
            for name in ["engineering", "production"] {
                let signingIn = try control(name)
                try check(!(signingIn is NSButton) && (signingIn as? NSTextField)?.stringValue == "Signing In…", "shared sign-in progress")
            }
            view.catalog = base; view.catalog["sourceChecks"] = [production.id: ["state": "checking", "expiresAt": expiration]]; view.render()
            try check((try control("production") as? NSTextField)?.stringValue == "Ready", "automatic renewal keeps healthy access ready")
            (try control("production", "aws-profile-details") as? NSButton)?.performClick(nil)
            let checkingButton = descendant(view.detailsPanel!.contentView!, "aws-details-check") as? NSButton
            try check(checkingButton?.title == "Checking…" && checkingButton?.isEnabled == false, "Details shows active checking")
            view.catalog["sourceChecks"] = [production.id: ["state": "ready", "checkedAt": expiration - 3500, "expiresAt": expiration]]
            view.tabs.selectedSegment = 1; view.render(); view.renderDetails()
            try check((descendant(view.detailsPanel!.contentView!, "aws-details-status") as? NSTextField)?.stringValue == "Access is ready.", "open Details updates after an asynchronous check")
            try check((descendant(view.detailsPanel!.contentView!, "aws-details-check") as? NSButton)?.title == "Check Access", "completed check restores Details action")
            try check(descendant(view.detailsPanel!.contentView!, "aws-details-sign-in") == nil, "healthy Details does not invite another login")
            for (name, id) in [("production", production.id), ("engineering", engineering.id)] {
                for failure in ["networkUnavailable", "accessDenied", "checkFailed", "notChecked"] {
                    view.catalog = base; view.catalog["sourceChecks"] = [id: ["state": failure]]
                    view.tabs.selectedSegment = 0; view.render()
                    (try control(name, "aws-profile-details") as? NSButton)?.performClick(nil)
                    try check(descendant(view.detailsPanel!.contentView!, "aws-details-sign-in") == nil, "non-authentication failures do not invite sign-in")
                }
            }
            for width in [420.0, 600.0] {
                view.detailsPanel!.setContentSize(NSSize(width: width, height: 700)); view.detailsPanel!.contentView!.layoutSubtreeIfNeeded()
                guard let detailsBody = view.detailsBody else { return false }
                try check(detailsBody.frame.minX >= 19 && detailsBody.frame.maxX <= width - 19, "Details fits narrow window")
            }
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
            let borrowed = TDBSessionClient()
            let embedded = TDBAWSAccessPanel(client: borrowed, workstationName: "This Mac", local: true)
            embedded.hostConnectionForTesting = true
            let fixtureWindow = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 480), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            fixtureWindow.contentView = embedded.view
            defer { embedded.stop(); fixtureWindow.close() }
            var embeddedRequests: [String] = []
            embedded.requestForTesting = { operation, _ in embeddedRequests.append(operation) }
            embedded.applyStatusSnapshot(["catalog": base, "state": "ready", "stale": false])
            try check(embedded.tabs.superview == nil && embedded.tabs.isHidden, "embedded AWS has no nested provider tabs")
            try check(!allSubviews(embedded.view).compactMap { ($0 as? NSTextField)?.stringValue }.contains("AWS Profiles"), "outer Accounts owns the heading")
            try check(!allSubviews(embedded.view).compactMap { ($0 as? NSButton)?.title }.contains("Done"), "outer Accounts owns dismissal")
            try check(embedded.subtitle.stringValue == "AWS profiles are available across tabs on This Mac.", "embedded scope is simple and machine-wide")
            for width in [480.0, 600.0, 1000.0] {
                fixtureWindow.setContentSize(NSSize(width: width, height: 480))
                embedded.view.layoutSubtreeIfNeeded(); embedded.list.layoutSubtreeIfNeeded()
                let clip = embedded.scroll.contentView.convert(embedded.scroll.contentView.bounds, to: embedded.view)
                let insetFrame = embedded.subtitle.superview!.frame
                try check(abs(insetFrame.minX - 16) < 1 && abs(insetFrame.maxX - (width - 16)) < 1 && abs(insetFrame.minY - 12) < 1 && abs(insetFrame.maxY - (embedded.view.bounds.height - 12)) < 1, "embedded AWS aligns to Accounts insets at width \(width)")
                for row in embedded.list.arrangedSubviews where row.identifier?.rawValue == "aws-profile-row" {
                    guard let name = descendant(row, "aws-profile-name"), let primary = descendant(row, "aws-profile-primary"), let details = descendant(row, "aws-profile-details"), let more = descendant(row, "aws-profile-actions") else { return false }
                    func rect(_ child: NSView) -> NSRect { child.superview!.convert(child.alignmentRect(forFrame: child.frame), to: embedded.view) }
                    let n = rect(name), a = rect(primary), d = rect(details), m = rect(more)
                    try check(n.width >= 140 && n.maxX <= a.minX - 8 && a.maxX <= d.minX - 8 && d.maxX <= m.minX - 8 && m.maxX <= clip.maxX + 1, "embedded columns align at width \(width)")
                }
            }
            var healthyEmbedded = base
            healthyEmbedded["sourceChecks"] = [production.id: ["state": "ready", "expiresAt": expiration]]
            embedded.applyStatusSnapshot(["catalog": healthyEmbedded, "state": "ready", "stale": false])
            guard let healthySource = embedded.list.arrangedSubviews.first(where: { (descendant($0, "aws-profile-name") as? NSTextField)?.stringValue == "production" }),
                  let healthyReceiver = embedded.list.arrangedSubviews.first(where: { (descendant($0, "aws-profile-name") as? NSTextField)?.stringValue == "migrated" }) else { return false }
            try check(descendant(healthySource, "aws-profile-state") == nil && (descendant(healthySource, "aws-profile-authentication") as? NSTextField)?.stringValue == "Sharing enabled" && (descendant(healthySource, "aws-profile-primary") as? NSTextField)?.stringValue == "Ready", "healthy embedded source has three lines and keeps Ready")
            embedded.view.layoutSubtreeIfNeeded(); embedded.list.layoutSubtreeIfNeeded()
            try check(abs(healthySource.frame.height - 80) < 1 && abs(healthyReceiver.frame.height - 80) < 1, "healthy embedded rows use the compact three-line height")
            try check(descendant(healthyReceiver, "aws-profile-state") == nil && (descendant(healthyReceiver, "aws-profile-authentication") as? NSTextField)?.stringValue == "From Fixture Mac", "healthy embedded receiver keeps concise provenance without a repeated renewal line")
            let embeddedCaptions = allSubviews(embedded.list).compactMap { ($0 as? NSTextField)?.stringValue }
            try check(embeddedCaptions.filter { $0 == "Managed access renews automatically when connected." }.count == 1 && !embeddedCaptions.contains { $0.contains("Details has checks") }, "embedded list has one short renewal caption")
            embedded.applyStatusSnapshot(["catalog": base, "state": "ready", "stale": false])
            guard let renewalRequired = embedded.list.arrangedSubviews.first(where: { (descendant($0, "aws-profile-name") as? NSTextField)?.stringValue == "production" }) else { return false }
            try check((descendant(renewalRequired, "aws-profile-state") as? NSTextField)?.stringValue == "Sign in to keep renewal working" && descendant(renewalRequired, "aws-profile-secondary") is NSButton, "compact healthy presentation preserves full renewal recovery state")
            var deniedEmbedded = healthyEmbedded
            deniedEmbedded["sourceChecks"] = [production.id: ["state": "accessDenied", "expiresAt": expiration]]
            embedded.applyStatusSnapshot(["catalog": deniedEmbedded, "state": "ready", "stale": false])
            guard let deniedRow = embedded.list.arrangedSubviews.first(where: { (descendant($0, "aws-profile-name") as? NSTextField)?.stringValue == "production" }) else { return false }
            try check(descendant(deniedRow, "aws-profile-state") != nil && (descendant(deniedRow, "aws-profile-primary") as? NSTextField)?.stringValue == "Access denied", "permission failures keep their full guidance")
            embedded.applyStatusSnapshot(["catalog": base, "state": "ready", "stale": false])
            embedded.showDetails(AWSProfilePresentation.rows(catalog: base).first { $0.id == production.id }!)
            try check(embedded.detailsPanel == nil && embedded.detailsBody?.superview != nil && !embedded.backButton.isHidden, "embedded Details stays in the Accounts pane")
            try check(descendant(embedded.view, "aws-details-auth-expiry") != nil && descendant(embedded.view, "aws-details-expiry-help") != nil, "inline Details separates unavailable sign-in end from credential expiry")
            guard let embeddedCheck = descendant(embedded.view, "aws-details-check") as? NSButton else { return false }
            embeddedCheck.performClick(nil)
            try check(embeddedRequests == ["aws.refresh"], "only explicit embedded Check Access submits provider work")
            embedded.backToProfiles()
            try check(embedded.detailsID == nil && embedded.tabs.selectedSegment == 0 && embedded.backButton.isHidden, "Back returns to AWS profiles")
            embedded.tabs.selectedSegment = 1; embedded.updateSubtitle(); embedded.render()
            try check(!embedded.backButton.isHidden && embedded.sharingButton.isHidden, "embedded Sharing is a secondary page with Back")
            embedded.backToProfiles()
            embedded.applyStatusSnapshot(["catalog": base, "state": "stale", "stale": true])
            let staleCount = embeddedRequests.count
            embedded.request("aws.signIn.start", ["profileId": production.id])
            try check(embeddedRequests.count == staleCount && embedded.status.stringValue.contains("last-known"), "stale snapshots remain visible and cannot mutate")
            try check(embedded.status.stringValue.hasPrefix("Updating AWS status on This Mac") && !embedded.status.stringValue.contains("Reconnect"), "connected metadata invalidation shows updating rather than false reconnect advice")
            embedded.applyStatusSnapshot(["catalog": [:], "state": "stale", "stale": true])
            let pendingProfileText = allSubviews(embedded.list).compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: " ")
            try check(pendingProfileText.contains("Updating AWS profiles") && !pendingProfileText.contains("Reconnect"), "empty connected cache also avoids false reconnect instructions")
            var failedSnapshot = base; failedSnapshot["phase"] = "AWS sign-in failed. Try again."
            embedded.applyStatusSnapshot(["catalog": failedSnapshot, "state": "ready", "stale": false])
            embedded.applyStatusSnapshot(["catalog": failedSnapshot, "state": "stale", "stale": true])
            embedded.applyStatusSnapshot(["catalog": failedSnapshot, "state": "ready", "stale": false])
            try check(embedded.status.stringValue == failedSnapshot["phase"] as? String, "fresh metadata restores the same failure phase after temporary updating feedback")
            embedded.actionError = "Could not save this change."
            embedded.applyStatusSnapshot(["catalog": failedSnapshot, "state": "stale", "stale": true])
            embedded.applyStatusSnapshot(["catalog": failedSnapshot, "state": "ready", "stale": false])
            try check(embedded.status.stringValue == embedded.actionError, "fresh metadata restores an action error before historical service phase")
            embedded.actionError = nil
            embedded.applyStatusSnapshot(["catalog": base, "state": "stale", "stale": true])
            embedded.applyStatusSnapshot(["catalog": base, "state": "ready", "stale": false])
            try check(embedded.status.stringValue.isEmpty, "fresh idle metadata clears temporary updating feedback")
            var statusOperations: [String] = [], pendingStatus: ((NSDictionary) -> Void)?
            embedded.statusRequestForTesting = { operation, completed in statusOperations.append(operation); pendingStatus = completed }
            embedded.start(); embedded.refresh()
            try check(statusOperations == ["aws.status"] && embeddedRequests.count == staleCount, "opening and repeated rendering only read one cached status request")
            embedded.stop()
            let beforeLate = embedded.catalog["signInProfile"] as? String
            pendingStatus?(["catalog": ["signInProfile": "late"], "state": "ready"])
            try check(embedded.catalog["signInProfile"] as? String == beforeLate && embedded.timer == nil && !borrowed.ended, "stop fences late status replies without ending the borrowed session")

            let remoteClient = TDBSessionClient(); remoteClient.workstationID = "fixture-remote"; remoteClient.workstationName = "Office Mac"
            let remote = TDBAWSAccessPanel(client: remoteClient, workstationName: "Office Mac", local: false)
            remote.hostConnectionForTesting = true
            defer { remote.stop() }
            var remoteMutations = 0, localSignIns = 0
            remote.requestForTesting = { _, _ in remoteMutations += 1 }
            remote.localSignInHandler = { descriptor in if descriptor["id"] as? String == production.id { localSignIns += 1 } }
            remote.applyStatusSnapshot(["catalog": base, "state": "ready", "stale": false])
            remote.showDetails(AWSProfilePresentation.rows(catalog: base).first { $0.id == production.id }!)
            try check(remote.subtitle.stringValue.contains("Office Mac") && remote.sharingButton.isHidden, "remote scope has no local sharing page")
            guard let remoteCheck = descendant(remote.view, "aws-details-check") as? NSButton,
                  let localSignIn = descendant(remote.view, "aws-details-local-sign-in") as? NSButton else { return false }
            try check(!remoteCheck.isEnabled, "remote Check Access is disabled until remote mutations are supported")
            remote.request("aws.signIn.start", ["profileId": production.id]); remote.checkAccess(production.id)
            remote.install(AWSProfilePresentation.rows(catalog: base).first { $0.id == incoming.id }!); remote.syncNow()
            try check(remoteMutations == 0, "all remote mutation entry points reject without local fallback")
            localSignIn.performClick(nil)
            try check(localSignIns == 1 && remoteMutations == 0, "explicit viewing-Mac sign-in callback does not mutate the remote Mac")
            var healthyRemote = base; healthyRemote["sourceChecks"] = [production.id: ["state": "ready"]]
            remote.applyStatusSnapshot(["catalog": healthyRemote, "state": "ready", "stale": false])
            try check(descendant(remote.view, "aws-details-local-sign-in") == nil, "healthy remote access does not invite login because cached SSO metadata is expired")
            remoteClient.workstationID = "another-Mac"
            let originalIDs = AWSProfilePresentation.rows(catalog: remote.catalog).map(\.id)
            remote.applyStatusSnapshot(["catalog": [:], "state": "ready"])
            try check(AWSProfilePresentation.rows(catalog: remote.catalog).map(\.id) == originalIDs && remote.status.stringValue.contains("workstation changed"), "changed client identity rejects a snapshot instead of switching scope")
            let recoveryClient = TDBSessionClient(); recoveryClient.workstationID = "source-recovery-Mac"
            let recoveryPanel = TDBAWSAccessPanel(client: recoveryClient, workstationName: "Source Mac", local: false)
            recoveryPanel.hostConnectionForTesting = true; recoveryPanel.remoteControlForTesting = true
            let recoveryWindow = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
            recoveryWindow.contentView = recoveryPanel.view
            var recoveryCatalog = base
            var recoveredAccounts = base["accounts"] as! [[String: Any]]
            for index in recoveredAccounts.indices where recoveredAccounts[index]["profileId"] as? String == production.id {
                recoveredAccounts[index]["incomingAvailable"] = true; recoveredAccounts[index]["incomingSourceNames"] = ["Viewing Mac"]; recoveredAccounts[index]["incomingExpires"] = expiration - 900
            }
            recoveryCatalog["accounts"] = recoveredAccounts
            recoveryCatalog["sourceChecks"] = [production.id: ["state": "signInRequired"]]
            var recoveryRequests: [(String, [String: Any])] = [], recoveryConfirmations = 0
            recoveryPanel.requestForTesting = { recoveryRequests.append(($0, $1)) }
            recoveryPanel.confirmInstallForTesting = { _, _ in recoveryConfirmations += 1 }
            recoveryPanel.applyStatusSnapshot(["catalog": recoveryCatalog, "state": "ready", "stale": false,
                "capabilities": ["canManage": true, "allowedOperations": ["aws.use", "aws.refresh"]]])
            recoveryPanel.view.layoutSubtreeIfNeeded(); recoveryPanel.list.layoutSubtreeIfNeeded()
            guard let recoveryRow = recoveryPanel.list.arrangedSubviews.first(where: { (descendant($0, "aws-profile-name") as? NSTextField)?.stringValue == "production" }),
                  let useRecovery = descendant(recoveryRow, "aws-profile-primary") as? NSButton else { return false }
            try check(useRecovery.title == "Use Shared Access…" && descendant(recoveryRow, "aws-profile-secondary") == nil, "native source recovery offers shared-provider handoff rather than another sign-in or false Ready")
            useRecovery.performClick(nil)
            try check(recoveryConfirmations == 1 && recoveryRequests.isEmpty, "source handoff always requires explicit migration confirmation")
            recoveryPanel.confirmInstallation(production.id, targetName: "production", stopSource: true)
            try check(recoveryRequests.count == 1 && recoveryRequests[0].0 == "aws.use" && recoveryRequests[0].1["stopSource"] as? Bool == true && recoveryRequests[0].1["replaceSource"] as? Bool == true, "only confirmed source recovery sends the scoped stopSource request")
            recoveryPanel.showDetails(AWSProfilePresentation.rows(catalog: recoveryCatalog).first { $0.id == production.id }!)
            try check(descendant(recoveryPanel.view, "aws-details-use-shared") != nil && descendant(recoveryPanel.view, "aws-details-local-sign-in") == nil && (descendant(recoveryPanel.view, "aws-details-status") as? NSTextField)?.stringValue.contains("switch this profile") == true, "source Details explains provider migration without repeating browser sign-in")
            let expectedIncomingClock = "Received credentials expire " + DateFormatter.localizedString(from: Date(timeIntervalSince1970: expiration - 900), dateStyle: .medium, timeStyle: .short)
            try check((descendant(recoveryPanel.view, "aws-details-expiry") as? NSTextField)?.stringValue == expectedIncomingClock, "received expiry comes from the proved incoming copy rather than a longer-lived local credential")
            let beforeRecoveryChanged = recoveryRequests.count
            recoveryPanel.applyStatusSnapshot(["catalog": base, "state": "ready", "stale": false, "capabilities": ["canManage": true, "allowedOperations": ["aws.use"]]])
            recoveryPanel.confirmInstallation(production.id, targetName: "production", stopSource: true)
            try check(recoveryRequests.count == beforeRecoveryChanged, "a stale confirmation cannot stop a source after incoming access disappears")
            recoveryPanel.stop(); recoveryWindow.close()

            let disconnectedLocal = TDBAWSAccessPanel(client: TDBSessionClient(), workstationName: "This Mac", local: true)
            disconnectedLocal.hostConnectionForTesting = true; disconnectedLocal.active = true
            var disconnectedMutations = 0
            disconnectedLocal.requestForTesting = { _, _ in disconnectedMutations += 1 }
            disconnectedLocal.applyStatusSnapshot(["catalog": base, "state": "ready", "stale": false])
            disconnectedLocal.hostConnectionForTesting = false
            disconnectedLocal.refresh(); disconnectedLocal.request("aws.source.enable", ["profileId": engineering.id])
            let disconnectedAction = disconnectedLocal.list.arrangedSubviews.first { (descendant($0, "aws-profile-name") as? NSTextField)?.stringValue == "engineering" }.flatMap { descendant($0, "aws-profile-primary") as? NSButton }
            try check(disconnectedLocal.snapshotStale && disconnectedLocal.snapshotState == "disconnected" && disconnectedMutations == 0 && disconnectedAction?.isEnabled == false, "disconnect independently marks cached local status stale and disables actions")
            disconnectedLocal.applyStatusSnapshot(["catalog": base, "state": "ready", "stale": false])
            disconnectedLocal.request("aws.source.enable", ["profileId": engineering.id])
            try check(disconnectedMutations == 0 && !disconnectedLocal.canMutate, "a late ready snapshot cannot restore mutation permission while local transport is disconnected")
            disconnectedLocal.stop()

            let controllerClient = TDBSessionClient(); controllerClient.workstationID = "controlled-Mac"
            let controlled = TDBAWSAccessPanel(client: controllerClient, workstationName: "Controlled Mac", local: false)
            controlled.remoteControlForTesting = true; controlled.hostConnectionForTesting = true
            var controlledOperations: [String] = []
            controlled.requestForTesting = { operation, _ in controlledOperations.append(operation) }
            let capabilities: [String: Any] = ["canManage": true, "requiresControl": false,
                "allowedOperations": ["aws.check", "aws.refresh", "aws.use", "aws.source.enable", "aws.remove", "aws.signIn.start", "aws.sync.now"]]
            controlled.applyStatusSnapshot(["catalog": base, "state": "ready", "stale": false, "capabilities": capabilities])
            controlled.checkAccess(engineering.id); controlled.checkAccess(production.id)
            controlled.request("aws.source.enable", ["profileId": engineering.id])
            controlled.install(AWSProfilePresentation.rows(catalog: base).first { $0.id == incoming.id }!)
            controlled.request("aws.remove", ["profileId": migrated.id])
            controlled.request("aws.signIn.start", ["profileId": production.id]); controlled.syncNow()
            try check(controlledOperations == ["aws.check", "aws.refresh", "aws.source.enable", "aws.use", "aws.remove"], "remote controller honors narrow operation allowlist and never sends browser sign-in or local sync")
            controlled.remoteControlForTesting = false
            controlled.checkAccess(engineering.id)
            try check(controlledOperations.count == 5, "loss of live controller ownership rejects a stale advertised capability")
            controlled.applyStatusSnapshot(["state": "unavailable", "stale": true, "message": "Update TerminalDB on Controlled Mac to show AWS accounts here."])
            try check(controlled.status.stringValue.contains("Update TerminalDB") && allSubviews(controlled.list).compactMap { ($0 as? NSTextField)?.stringValue }.contains { $0.contains("Update TerminalDB") }, "rolling-upgrade status offers update guidance rather than empty profiles or sign-in")
            controlled.stop()

            let authClient = TDBSessionClient(); authClient.workstationID = "auth-execution-Mac"
            let auth = TDBAWSAccessPanel(client: authClient, workstationName: "Execution Mac", local: false)
            auth.active = true; auth.hostConnectionForTesting = true
            var localAuthOperations: [(String, NSDictionary)] = [], localAuthCallbacks: [(String, (NSDictionary) -> Void)] = []
            auth.localAuthRequestForTesting = { operation, payload, completed in
                localAuthOperations.append((operation, payload))
                if operation == "aws.signIn.start" { completed(["accepted": true, "signInAttempt": "00000000-0000-4000-8000-000000000001"]) }
                else if operation == "aws.signIn.cancel" { completed(["accepted": true]) }
                else { localAuthCallbacks.append((operation, completed)) }
            }
            auth.applyStatusSnapshot(["catalog": base, "state": "ready", "stale": false])
            let executionCatalog = AWSProfilePresentation.rows(catalog: auth.catalog).map(\.id)
            auth.beginLocalSignIn(try object(production) as NSDictionary)
            try check(localAuthOperations.map(\.0) == ["aws.signIn.start", "aws.status"] && localAuthOperations[0].1["profileId"] as? String == production.id && (localAuthOperations[0].1["descriptor"] as? NSDictionary)?["id"] as? String == production.id, "viewer-local coordinator sends selected descriptor only to its distinct local transport")
            try check(authClient.workstationID == "auth-execution-Mac" && AWSProfilePresentation.rows(catalog: auth.catalog).map(\.id) == executionCatalog, "local browser flow never replaces the execution client or catalog")
            auth.applyLocalAuthStatus(["catalog": ["signInProfile": "", "phase": "SSO session signed in."], "state": "ready", "updatedAt": auth.localAuthSubmittedAt - 1])
            try check(auth.localAuthMonitoring && auth.localAuthCancelable, "a pre-start cached completion is not a fresh sign-in result")
            auth.applyLocalAuthStatus(["catalog": ["signInProfile": production.id, "signInAttempt": "00000000-0000-4000-8000-000000000001"], "state": "ready"])
            auth.cancelLocalSignIn()
            try check(localAuthOperations.last?.0 == "aws.signIn.cancel" && localAuthOperations.last?.1["profileId"] as? String == production.id && localAuthOperations.last?.1["signInAttempt"] as? String == "00000000-0000-4000-8000-000000000001" && !auth.localAuthCancelable, "Cancel targets the tracked local sign-in only")
            try check(localAuthOperations.allSatisfy { ["aws.signIn.start", "aws.signIn.cancel", "aws.status"].contains($0.0) }, "local auth never enables sharing, imports profiles or configures peers automatically")
            auth.beginLocalSignIn(try object(production) as NSDictionary)
            auth.applyLocalAuthStatus(["catalog": ["signInProfile": production.id, "signInAttempt": "00000000-0000-4000-8000-000000000001"], "state": "ready"])
            auth.applyLocalAuthStatus(["catalog": ["signInProfile": "", "phase": "AWS sign-in did not finish."], "state": "ready", "updatedAt": Date().timeIntervalSince1970])
            try check(auth.localAuthBanner.stringValue.contains("needs attention") && !auth.localAuthMonitoring, "failed browser completion is not presented as signed in")
            auth.beginLocalSignIn(try object(production) as NSDictionary)
            auth.applyLocalAuthStatus(["catalog": ["signInProfile": production.id, "signInAttempt": "00000000-0000-4000-8000-000000000002"], "state": "ready"])
            let beforeWrongAttemptCancel = localAuthOperations.count
            auth.cancelLocalSignIn()
            try check(!auth.localAuthCancelable && localAuthOperations.count == beforeWrongAttemptCancel && auth.localAuthBanner.stringValue.contains("Another sign-in"), "same-profile replacement attempt cannot be cancelled by an old view")
            auth.beginLocalSignIn(try object(production) as NSDictionary)
            let lateAuthReply = localAuthCallbacks.last!.1
            auth.stop(); Self.localSignInToResume = nil; Self.localSignInAttemptToResume = nil; let stoppedBanner = auth.localAuthBanner.stringValue
            lateAuthReply(["catalog": ["signInProfile": production.id, "signInAttempt": "00000000-0000-4000-8000-000000000001"], "state": "ready"])
            try check(auth.localAuthBanner.stringValue == stoppedBanner && auth.localAuthClient == nil && authClient.workstationID == "auth-execution-Mac", "closing Accounts fences late local auth replies and preserves the remote target")

            let uncertainClient = TDBSessionClient(); uncertainClient.workstationID = "uncertain-execution-Mac"
            let uncertainAuth = TDBAWSAccessPanel(client: uncertainClient, workstationName: "Execution Mac", local: false)
            uncertainAuth.active = true; uncertainAuth.hostConnectionForTesting = true
            var uncertainOperations: [String] = []
            uncertainAuth.localAuthRequestForTesting = { operation, _, completed in
                uncertainOperations.append(operation)
                if operation == "aws.signIn.start" { completed(["uncertain": true, "error": "The request timed out."]) }
            }
            uncertainAuth.statusRequestForTesting = { _, completed in completed(["catalog": base, "state": "ready", "stale": false]) }
            uncertainAuth.beginLocalSignIn(try object(production) as NSDictionary)
            try check(uncertainAuth.localAuthMonitoring && uncertainAuth.localAuthUncertain && !uncertainAuth.localAuthCancelable && Self.localSignInToResume == production.id && uncertainAuth.localAuthBanner.stringValue.contains("will not repeat"), "uncertain start retains observation metadata without claiming failure or allowing cancel")
            uncertainAuth.beginLocalSignIn(try object(production) as NSDictionary)
            uncertainAuth.stop(); uncertainAuth.start()
            try check(uncertainOperations.filter { $0 == "aws.signIn.start" }.count == 1, "uncertain start is not replayed by repeated actions or reopening")
            uncertainAuth.applyLocalAuthStatus(["catalog": ["signInProfile": production.id, "signInAttempt": "00000000-0000-4000-8000-000000000099"], "state": "ready", "updatedAt": Date().timeIntervalSince1970])
            uncertainAuth.cancelLocalSignIn()
            try check(uncertainAuth.localAuthAttempt == nil && !uncertainAuth.localAuthObserved && !uncertainAuth.localAuthCancelable && !uncertainOperations.contains("aws.signIn.cancel"), "uncertain request never adopts or cancels another same-profile attempt")
            uncertainAuth.applyLocalAuthStatus(["catalog": ["signInProfile": "", "phase": "SSO session signed in."], "state": "ready", "updatedAt": Date().timeIntervalSince1970])
            try check(uncertainAuth.localAuthMonitoring && uncertainAuth.localAuthUncertain && uncertainAuth.localAuthBanner.stringValue.contains("still unconfirmed") && !uncertainAuth.localAuthBanner.stringValue.contains("finished"), "fresh idle cache cannot resolve an unacknowledged request that may remain queued")
            uncertainAuth.stop(); Self.localSignInToResume = nil; Self.localSignInAttemptToResume = nil; Self.localSignInUncertainToResume = false

            let closingClient = TDBSessionClient(); closingClient.workstationID = "closing-execution-Mac"
            let closingAuth = TDBAWSAccessPanel(client: closingClient, workstationName: "Execution Mac", local: false)
            closingAuth.active = true; closingAuth.hostConnectionForTesting = true
            var closingOperations: [String] = []
            closingAuth.localAuthRequestForTesting = { operation, _, _ in closingOperations.append(operation) }
            closingAuth.statusRequestForTesting = { _, completed in completed(["catalog": base, "state": "ready", "stale": false]) }
            closingAuth.beginLocalSignIn(try object(production) as NSDictionary)
            try check(closingAuth.localAuthWasSubmitted && closingAuth.localAuthStarting && closingAuth.localAuthSubmittedAt == 0, "synthetic start remains submitted before acknowledgement")
            closingAuth.stop(); closingAuth.start()
            closingAuth.applyLocalAuthStatus(["catalog": ["signInProfile": "", "phase": "SSO session signed in."], "state": "ready", "updatedAt": Date().timeIntervalSince1970])
            try check(closingAuth.localAuthMonitoring && closingAuth.localAuthUncertain && closingAuth.localAuthBanner.stringValue.contains("still unconfirmed"), "closing before acknowledgement cannot treat updatedAt greater than zero as completion")
            closingAuth.applyLocalAuthStatus(["catalog": ["signInProfile": production.id, "signInAttempt": "00000000-0000-4000-8000-000000000099"], "state": "ready", "updatedAt": Date().timeIntervalSince1970])
            closingAuth.cancelLocalSignIn()
            try check(closingAuth.localAuthAttempt == nil && !closingAuth.localAuthCancelable && closingOperations.filter { $0 == "aws.signIn.start" }.count == 1 && !closingOperations.contains("aws.signIn.cancel"), "reopened unacknowledged submission never adopts an unrelated same-profile attempt or replays start")
            closingAuth.stop(); Self.localSignInToResume = nil; Self.localSignInAttemptToResume = nil; Self.localSignInUncertainToResume = false; Self.localSignInAcknowledgedAt = nil

            let invalidRemote = TDBAWSAccessPanel(client: TDBSessionClient(), workstationName: "Remote Mac", local: false)
            invalidRemote.applyStatusSnapshot(["catalog": base, "state": "ready"])
            try check(invalidRemote.catalog.isEmpty && !invalidRemote.clientMatchesWorkstation, "a remote view never falls back to an empty local workstation identity")

            print("AWS interface layout checks passed: \(checks)")
            return true
        } catch {
            let detail = (error as? PeerFailure)?.message ?? "fixtures could not be prepared"
            FileHandle.standardError.write(Data(("AWS interface regression failed: " + detail + "\n").utf8))
            return false
        }
    }

    private override convenience init() {
        self.init(client: TDBSessionClient(), workstationName: "This Mac", local: true, embedded: false)
    }

    /// The embedded view borrows a dedicated client for one execution Mac.
    /// Closing Accounts never disconnects the terminal or changes its profile.
    @objc(initWithClient:workstationName:local:)
    public convenience init(client: TDBSessionClient, workstationName: String, local: Bool) {
        self.init(client: client, workstationName: workstationName, local: local, embedded: true)
    }

    private init(client: TDBSessionClient, workstationName: String, local: Bool, embedded: Bool) {
        host = client; self.embedded = embedded; isLocalWorkstation = local
        self.workstationName = PeerProtocol.displayName(workstationName)
        workstationIdentifier = client.workstationID
        super.init()
        view.identifier = .init("aws-accounts-content")
        let title = NSTextField(labelWithString: "AWS Profiles")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.identifier = .init("aws-accounts-scope")
        tabs.selectedSegment = 0; tabs.target = self; tabs.action = #selector(changeTab)
        tabs.setAccessibilityLabel("AWS access view")
        tabs.isHidden = embedded
        list.orientation = .vertical; list.alignment = .leading; list.spacing = 0
        list.identifier = .init("AWSProfiles")
        list.autoresizingMask = [.width]
        scroll.documentView = list; scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: embedded ? 140 : 220).isActive = true
        helpButton.target = self; helpButton.action = #selector(showHelp); helpButton.isBordered = false
        sharingButton.target = self; sharingButton.action = #selector(openSharing)
        sharingButton.isBordered = false; sharingButton.identifier = .init("aws-accounts-sharing")
        sharingButton.isHidden = !embedded || !local
        backButton.target = self; backButton.action = #selector(backToProfiles)
        backButton.isBordered = false; backButton.identifier = .init("aws-accounts-back")
        backButton.isHidden = true
        let done = NSButton(title: "Done", target: self, action: #selector(closePanel)); done.keyEquivalent = "\u{1b}"
        cancel.target = self; cancel.action = #selector(cancelSignIn); cancel.isHidden = true
        let footerViews: [NSView] = embedded ? [backButton, sharingButton, NSView(), cancel, helpButton] : [helpButton, NSView(), cancel, done]
        let footer = NSStackView(views: footerViews); footer.orientation = .horizontal; footer.spacing = 12
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        status.setAccessibilityLabel("AWS access status")
        localAuthBanner.font = .systemFont(ofSize: 12); localAuthBanner.textColor = .secondaryLabelColor
        localAuthBanner.identifier = .init("aws-local-sign-in-status")
        localAuthCancel.target = self; localAuthCancel.action = #selector(cancelLocalSignIn)
        localAuthCancel.identifier = .init("aws-local-sign-in-cancel")
        localAuthSharing.target = self; localAuthSharing.action = #selector(showLocalSharing)
        localAuthSharing.isBordered = false; localAuthSharing.identifier = .init("aws-local-sign-in-sharing")
        let localAuthActions = NSStackView(views: [localAuthCancel, NSView(), localAuthSharing])
        localAuthActions.orientation = .horizontal; localAuthActions.spacing = 12
        localAuthSection.orientation = .vertical; localAuthSection.alignment = .leading; localAuthSection.spacing = 8
        localAuthSection.addArrangedSubview(localAuthBanner); localAuthSection.addArrangedSubview(localAuthActions)
        for child in localAuthSection.arrangedSubviews { child.widthAnchor.constraint(equalTo: localAuthSection.widthAnchor).isActive = true }
        localAuthSection.isHidden = true
        let contentViews: [NSView] = embedded ? [subtitle, localAuthSection, scroll, status, footer] : [title, subtitle, tabs, scroll, status, footer]
        let stack = NSStackView(views: contentViews)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let horizontalInset: CGFloat = embedded ? 16 : 24
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: horizontalInset),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -horizontalInset),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: embedded ? 12 : 24),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: embedded ? -12 : -22)
        ])
        for child in stack.arrangedSubviews { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        if !embedded {
            panel.title = "AWS Access — " + PeerProtocol.displayName(Host.current().localizedName ?? "This Mac")
            panel.isReleasedWhenClosed = false; panel.delegate = self
            panel.contentView = view; panel.minSize = NSSize(width: 600, height: 520)
        }
        agent.agentManagement = true
        updateSubtitle()
    }

    private var clientMatchesWorkstation: Bool {
        host.workstationID == workstationIdentifier && isLocalWorkstation == workstationIdentifier.isEmpty
    }
    private var ownerWindow: NSWindow? { view.window }
    private var hostIsConnected: Bool { hostConnectionForTesting ?? host.connected }
    private var remoteControlActive: Bool { remoteControlForTesting ?? (hostIsConnected && host.controlling) }
    private var canMutate: Bool { hostIsConnected && clientMatchesWorkstation && !snapshotStale && (isLocalWorkstation || (remoteCanManage && remoteControlActive)) }
    private func allows(_ operation: String) -> Bool {
        guard canMutate else { return false }
        if isLocalWorkstation { return true }
        let supported: Set<String> = ["aws.check", "aws.refresh", "aws.use", "aws.source.enable", "aws.remove"]
        return supported.contains(operation) && allowedRemoteOperations.contains(operation)
    }
    private func scoped(_ text: String) -> String {
        isLocalWorkstation ? text : text.replacingOccurrences(of: "This Mac", with: workstationName)
    }

    @objc public func start() {
        guard !active else { return }
        active = true; lifecycle += 1
        if embedded && localAuthProfileID == nil, let profileID = Self.localSignInToResume {
            localAuthProfileID = profileID; localAuthAttempt = Self.localSignInAttemptToResume; localAuthMonitoring = true
            localAuthUncertain = Self.localSignInUncertainToResume || localAuthAttempt == nil
            localAuthSubmittedAt = Self.localSignInAcknowledgedAt ?? 0
            localAuthSection.isHidden = false; localAuthCancel.isHidden = true
            localAuthBanner.stringValue = "Checking the sign-in started on This Mac…"
        }
        if localAuthMonitoring { connectLocalAuth { [weak self] in self?.refreshLocalAuth() } }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    @objc public func stop() {
        active = false; lifecycle += 1; statusRequestPending = false; pending = false
        timer?.invalidate(); timer = nil
        detailsPanel?.close()
        localAuthClient?.close(); localAuthClient = nil; localAuthStatusPending = false
        if localAuthStarting && !localAuthWasSubmitted {
            localAuthMonitoring = false
            if Self.localSignInToResume == localAuthProfileID { Self.localSignInToResume = nil; Self.localSignInAttemptToResume = nil }
        }
        if localAuthMonitoring && localAuthWasSubmitted && localAuthAttempt == nil {
            localAuthUncertain = true
            if Self.localSignInToResume == localAuthProfileID { Self.localSignInUncertainToResume = true }
        }
        localAuthStarting = false
        if !embedded { host.close() }
        agent.close()
    }

    @objc(applyStatusSnapshot:)
    public func applyStatusSnapshot(_ snapshot: NSDictionary) {
        guard clientMatchesWorkstation else {
            status.stringValue = "This workstation changed. Reopen Accounts to view its AWS access."
            return
        }
        if let identity = snapshot["workstationID"] as? String, identity != workstationIdentifier { return }
        if let error = snapshot["error"] as? String {
            snapshotStale = true; snapshotState = "unavailable"; snapshotMessage = error
            status.stringValue = error; render(); renderDetails(); return
        }
        let wasStale = snapshotStale
        let envelope = snapshot["catalog"] as? [String: Any]
        let capabilities = snapshot["capabilities"] as? [String: Any] ?? [:]
        allowedRemoteOperations = Set(capabilities["allowedOperations"] as? [String] ?? [])
        remoteCanManage = capabilities["canManage"] as? Bool == true
        remoteRequiresControl = capabilities["requiresControl"] as? Bool == true
        snapshotState = snapshot["state"] as? String ?? "ready"
        snapshotMessage = snapshot["message"] as? String
        snapshotStale = snapshot["stale"] as? Bool == true || snapshotState != "ready"
        catalog = envelope ?? (snapshot as? [String: Any] ?? [:])
        cancel.isHidden = !isLocalWorkstation || (catalog["signInProfile"] as? String ?? "").isEmpty
        applyCatalogStatus(catalog, restoreFreshState: wasStale && !snapshotStale)
        if snapshotStale {
            let fallback: String
            if hostIsConnected {
                fallback = (snapshotState == "unavailable" ? "AWS status is unavailable on " + workstationName + "." : "Updating AWS status on " + workstationName + "…") +
                    (catalog.isEmpty ? "" : " Showing last-known details.")
            } else {
                fallback = "Reconnect " + workstationName + " to update AWS status." + (catalog.isEmpty ? "" : " Showing last-known details.")
            }
            status.stringValue = snapshotMessage ?? fallback
        } else if actionError == nil && !pending && (catalog["phase"] as? String ?? "").isEmpty {
            status.stringValue = ""
        }
        updateSubtitle(); render(); renderDetails()
        statusDidChange?(snapshot)
    }

    private func show() {
        panel.center(); panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        host.connect { [weak self] _ in self?.refresh() }
        agent.connect { [weak self] _ in self?.refresh() }
        start()
    }

    private func label(_ text: String, small: Bool = false) -> NSTextField {
        let view = NSTextField(wrappingLabelWithString: text)
        view.textColor = .secondaryLabelColor
        view.font = .systemFont(ofSize: 12)
        return view
    }

    private func updateSubtitle() {
        if embedded {
            if detailsID != nil {
                subtitle.stringValue = "Profile details · " + workstationName
            } else if tabs.selectedSegment == 1 {
                subtitle.stringValue = "Choose paired Macs for AWS sharing. Approval is required on both Macs."
            } else {
                subtitle.stringValue = "AWS profiles are available across tabs on " + workstationName + "."
            }
            backButton.isHidden = detailsID == nil && tabs.selectedSegment == 0
            sharingButton.isHidden = !isLocalWorkstation || detailsID != nil || tabs.selectedSegment != 0
            helpButton.isHidden = detailsID != nil
        } else {
            subtitle.stringValue = tabs.selectedSegment == 0
                ? "Manage profiles for commands on This Mac. Existing profiles are detected automatically."
                : "Choose which paired Macs may exchange selected AWS access. Approval is required on both Macs."
        }
    }

    @objc private func openSharing() {
        guard isLocalWorkstation else { return }
        detailsID = nil; detailsBody = nil; tabs.selectedSegment = 1
        if embedded && !agent.connected { agent.connect { [weak self] _ in self?.refresh() } }
        changeTab()
    }

    @objc private func backToProfiles() {
        detailsID = nil; detailsBody = nil; detailsActions.removeAll(); detailsSignature = ""
        tabs.selectedSegment = 0; changeTab()
    }

    @objc private func changeTab() {
        rowsSignature = ""; updateSubtitle(); render(); refresh()
    }

    private func refresh() {
        guard active else { return }
        guard clientMatchesWorkstation else {
            status.stringValue = "This workstation changed. Reopen Accounts to view its AWS access."
            return
        }
        if (hostIsConnected || statusRequestForTesting != nil) && !statusRequestPending {
            statusRequestPending = true
            let generation = lifecycle
            let completed: (NSDictionary) -> Void = { [weak self] result in
                guard let self, self.active, self.lifecycle == generation, self.clientMatchesWorkstation else { return }
                self.statusRequestPending = false
                self.applyStatusSnapshot(result)
            }
            if let statusRequestForTesting { statusRequestForTesting("aws.status", completed) }
            else { host.request("aws.status", payload: [:], completion: completed) }
        } else if !hostIsConnected {
            let message = isLocalWorkstation ? "Reconnect this Mac’s background service to update AWS access." : "Reconnect \(workstationName) to view its AWS access."
            applyStatusSnapshot(["catalog": catalog, "state": "disconnected", "stale": true, "message": message,
                "summary": TDBAWSStatusModel.fallbackSummary(for: "disconnected")])
        }
        refreshLocalAuth()
        if agent.connected && (!embedded || tabs.selectedSegment == 1) {
            let generation = lifecycle
            agent.request("peers.state", payload: [:]) { [weak self] result in
                guard let self, self.active, self.lifecycle == generation else { return }
                self.peerState = result as? [String: Any] ?? [:]; self.render(); self.renderDetails()
            }
        }
    }

    private func applyCatalogStatus(_ result: [String: Any], restoreFreshState: Bool = false) {
        let phase = result["phase"] as? String ?? ""
        let changed = lastPhase.map { $0 != phase } ?? false
        let signingIn = !(result["signInProfile"] as? String ?? "").isEmpty
        if !pending { lastPhase = phase }
        if let error = actionError { status.stringValue = error }
        else if !pending && restoreFreshState { status.stringValue = phase }
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
        value.isEnabled = !pending && canMutate
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
                    "installed": catalog["installed"] ?? [], "sourceStatus": catalog["sourceStatus"] ?? [:], "sourceChecks": catalog["sourceChecks"] ?? [:],
                    "usable": AWSProfilePresentation.rows(catalog: catalog).filter { $0.usableExpiration() != nil }.map(\.id),
                    "sources": catalog["sources"] ?? [], "signIn": catalog["signInProfile"] ?? "",
                    "signInProfiles": catalog["signInProfiles"] ?? [], "authentication": catalog["authentication"] ?? [:],
                    "awsPeers": peerState["awsPeers"] ?? []]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return }
        let signature = "\(syncing):\(pending):\(detailsID ?? ""):\(isLocalWorkstation):\(snapshotStale):\(remoteCanManage):\(remoteControlActive):\(allowedRemoteOperations.sorted()):" + String(decoding: data, as: UTF8.self)
        guard signature != rowsSignature else { return }
        let position = scroll.contentView.bounds.origin
        rowsSignature = signature; clearRows()
        if embedded && detailsID != nil {
            let body = NSStackView(); body.orientation = .vertical; body.alignment = .leading; body.spacing = 12
            addRow(body); detailsBody = body; detailsSignature = ""; renderDetails()
        } else if syncing { renderMacs() } else { renderProfiles() }
        list.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: list.fittingSize.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(position.y, max(0, list.frame.height - scroll.contentSize.height))))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func renderMacs() {
        guard isLocalWorkstation, agent.connected else {
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
            choice.state = enabled.contains(id) ? .on : .off; choice.isEnabled = canMutate
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

    private func recoversNativeSource(_ item: AWSProfilePresentation) -> Bool {
        item.needsIncomingSourceRecovery(isSource: (catalog["sources"] as? [String] ?? []).contains(item.id))
    }

    private func profileActionView(_ action: AWSProfileRowAction, item: AWSProfilePresentation, secondary: Bool) -> NSView {
        let remoteOperation: String?
        switch action {
        case .shareAccess: remoteOperation = "aws.source.enable"
        case .useSharedAccess: remoteOperation = "aws.use"
        case .refreshAccess: remoteOperation = "aws.refresh"
        default: remoteOperation = nil
        }
        if !isLocalWorkstation && !(remoteOperation.map { allows($0) } ?? false) && ![.ready, .signingIn, .refreshing, .accessDenied, .checkFailed, .networkUnavailable].contains(action) {
            if (action == .signIn || action == .signInAgain), item.sourceCheck.state == "signInRequired", localSignInHandler != nil {
                let value = NSButton(title: "Sign In Here…", target: self, action: #selector(invokeAction(_:)))
                buttonActions[ObjectIdentifier(value)] = { [weak self] in self?.requestLocalSignIn(item.id) }
                value.isEnabled = !pending && !snapshotStale
                value.toolTip = "Sign in on This Mac, then share access with " + workstationName + " through your approved connection."
                value.setAccessibilityLabel("Sign in on This Mac for " + item.name)
                return value
            }
            let title: String
            switch action {
            case .signIn, .signInAgain: title = "Sign-in needed"
            case .shareAccess: title = item.usableExpiration() != nil ? "Ready" : "Not checked"
            case .useSharedAccess: title = "Ready to use"
            case .syncNow: title = "Waiting for access"
            case .review: title = "Needs review"
            default: title = "Manage on " + workstationName
            }
            let field = NSTextField(labelWithString: title); field.font = .systemFont(ofSize: 12, weight: .medium)
            field.textColor = .secondaryLabelColor; field.alignment = .center
            return field
        }
        switch action {
        case .ready, .signingIn, .refreshing, .accessDenied, .checkFailed, .networkUnavailable:
            let value = NSTextField(labelWithString: action.title)
            value.font = .systemFont(ofSize: 12, weight: action == .ready ? .semibold : .regular)
            value.textColor = action == .ready ? .labelColor : .secondaryLabelColor
            value.alignment = .center
            value.setAccessibilityLabel(action.title)
            return value
        default:
            let title: String
            if action == .useSharedAccess {
                title = recoversNativeSource(item) ? "Use Shared Access…" : scoped(action.title) + (canInstallImmediately(item) ? "" : "…")
            } else {
                title = action.title
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
        case .signIn, .signInAgain:
            if isLocalWorkstation { request("aws.signIn.start", ["profileId": item.id]) }
            else { requestLocalSignIn(item.id) }
        case .shareAccess: request("aws.source.enable", ["profileId": item.id])
        case .useSharedAccess: install(item)
        case .syncNow: syncNow()
        case .refreshAccess: request("aws.refresh", ["profileId": item.id])
        case .review: showDetails(item)
        case .ready, .signingIn, .refreshing, .accessDenied, .checkFailed, .networkUnavailable: break
        }
    }

    private func sharingSetupRow(_ copy: String, buttonTitle: String) -> NSStackView {
        let text = label(copy)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let setup = button(buttonTitle) { [weak self] in
            guard let self else { return }; self.openSharing()
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
            if snapshotStale {
                let waiting = snapshotState == "loading" ? "Loading AWS profiles…" : hostIsConnected
                    ? (snapshotState == "unavailable" ? "AWS profiles are unavailable on " + workstationName + "." : "Updating AWS profiles on " + workstationName + "…")
                    : "Reconnect " + workstationName + " to update its AWS profiles."
                addRow(NSStackView(views: [label(snapshotMessage ?? waiting)]))
                return
            }
            if !isLocalWorkstation {
                addRow(NSStackView(views: [label("No AWS profiles are available on " + workstationName + ". Configure AWS on that Mac to see its profiles here.")]))
                return
            }
            if embedded {
                addRow(NSStackView(views: [label("No AWS profiles on This Mac."), label("Profiles in your AWS CLI configuration appear here automatically. Use Sharing to receive access from an approved Mac.")]))
                return
            }
            addRow(sharingSetupRow("Receive AWS access from another Mac in Sharing. Profiles you already use with the AWS CLI appear here automatically.", buttonTitle: "Set Up Sharing"))
            return
        }
        if isLocalWorkstation && !sources.isEmpty && (peerState["awsPeers"] as? [String] ?? []).isEmpty && (!embedded || agent.connected) {
            addRow(sharingSetupRow("Choose which Macs receive the profiles you share.", buttonTitle: "Choose Macs"))
        }
        let actionWidth: CGFloat = embedded ? (profileRows.contains(where: recoversNativeSource) ? 144 : 120) : 140
        for item in profileRows {
            let id = item.id, source = sources.contains(item.id)
            let presentation = item.rowState(isSource: source, sourceStatus: states[id], isSigningIn: signingIn.contains(id))
            let healthyAction = presentation.primaryAction.map { [.ready, .shareAccess, .useSharedAccess].contains($0) } ?? false
            let compactHealthy = embedded && !snapshotStale && healthyAction && item.usableExpiration() != nil &&
                !presentation.needsAttention && !signingIn.contains(id)
            let provenance: String
            if compactHealthy {
                if source { provenance = "Sharing enabled" }
                else if item.isInstalled || !item.sourceNames.isEmpty { provenance = scoped(presentation.authenticationText) }
                else { provenance = "Not shared" }
            } else { provenance = scoped(presentation.authenticationText) }
            let title = NSTextField(labelWithString: item.name)
            title.font = .systemFont(ofSize: 14, weight: .semibold)
            title.identifier = .init("aws-profile-name"); title.setAccessibilityIdentifier("aws-profile-name")
            let identity = NSTextField(labelWithString: item.identitySummary)
            let authentication = NSTextField(labelWithString: provenance)
            authentication.identifier = .init("aws-profile-authentication"); authentication.setAccessibilityIdentifier("aws-profile-authentication")
            authentication.font = .systemFont(ofSize: 12)
            authentication.textColor = .secondaryLabelColor
            let state = NSTextField(labelWithString: presentation.availabilityText)
            identity.identifier = .init("aws-profile-identity"); state.identifier = .init("aws-profile-state")
            for field in [title, identity, authentication, state] {
                field.lineBreakMode = .byTruncatingMiddle; field.maximumNumberOfLines = 1
                field.toolTip = field.stringValue
                field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            }
            for field in [identity, state] { field.font = .systemFont(ofSize: 12); field.textColor = .secondaryLabelColor }
            state.textColor = presentation.needsAttention ? .systemOrange : .secondaryLabelColor
            authentication.lineBreakMode = .byTruncatingTail
            authentication.toolTip = presentation.authenticationTooltip
            let actionColumn = NSStackView(); actionColumn.orientation = .vertical; actionColumn.alignment = .centerX; actionColumn.spacing = 4
            actionColumn.identifier = .init("aws-profile-action-column")
            actionColumn.setHuggingPriority(.required, for: .vertical)
            let visibleActions = (isLocalWorkstation ? [presentation.primaryAction, presentation.secondaryAction] : [presentation.primaryAction, presentation.secondaryAction == .signIn ? .signIn : nil]).compactMap { $0 }
            for (index, action) in visibleActions.enumerated() {
                let view = profileActionView(action, item: item, secondary: index == 1)
                view.identifier = .init(index == 0 ? "aws-profile-primary" : "aws-profile-secondary")
                view.translatesAutoresizingMaskIntoConstraints = false
                actionColumn.addArrangedSubview(view)
                view.widthAnchor.constraint(equalTo: actionColumn.widthAnchor).isActive = true
                view.heightAnchor.constraint(equalToConstant: view is NSButton ? 28 : 16).isActive = true
            }
            let menu = NSMenu(); menu.autoenablesItems = false; menu.delegate = self
            if isLocalWorkstation && !visibleActions.contains(.signIn) && (item.hasLocalProfile || item.isInstalled || source) {
                addMenuItem("Sign In Here…", to: menu, enabled: (catalog["signInProfile"] as? String ?? "").isEmpty) { [weak self] in self?.request("aws.signIn.start", ["profileId": id]) }
            }
            if allows("aws.source.enable") && !source && item.hasLocalProfile && !visibleActions.contains(.shareAccess) {
                addMenuItem(scoped("Share This Mac’s Access"), to: menu) { [weak self] in self?.request("aws.source.enable", ["profileId": id]) }
            }
            if allows("aws.use") && item.isInstalled {
                addMenuItem("Use Another Profile Name…", to: menu) { [weak self] in
                    guard let self else { return }
                    let rows = AWSProfilePresentation.rows(catalog: self.catalog)
                    let current = rows.first { $0.id == id } ?? item
                    let suggested = current.suggestedAdditionalName(rows: rows, occupiedNames: Set(self.catalog["localProfileNames"] as? [String] ?? []))
                    self.install(current, suggestedName: suggested)
                }
            }
            if allows("aws.remove") && (source || item.isInstalled) {
                menu.addItem(.separator())
                addMenuItem(scoped("Remove from This Mac…"), to: menu) { [weak self] in self?.remove(id: id, name: item.name) }
            }
            let more = NSButton(image: NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Profile actions") ?? NSImage(), target: self, action: #selector(showActions(_:)))
            more.isBordered = false; more.menu = menu; more.isEnabled = !pending && !menu.items.isEmpty; more.isHidden = menu.items.isEmpty
            more.identifier = .init("aws-profile-actions"); more.setAccessibilityLabel("Actions for \(item.name)")
            more.toolTip = "Profile actions"
            let details = button("Details") { [weak self] in self?.showDetails(item) }
            details.isEnabled = !pending
            details.identifier = .init("aws-profile-details"); details.setAccessibilityLabel("Details for " + item.name)
            let row = NSView(); row.identifier = .init("aws-profile-row"); row.translatesAutoresizingMaskIntoConstraints = false
            let divider = NSBox(); divider.boxType = .separator
            let children: [NSView] = [title, identity] + (presentation.showsAuthentication ? [authentication] : []) + (compactHealthy ? [] : [state]) + [actionColumn, details, more, divider]
            for child in children { child.translatesAutoresizingMaskIntoConstraints = false; row.addSubview(child) }
            list.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor, constant: -12),
                row.heightAnchor.constraint(equalToConstant: compactHealthy ? 80 : (presentation.showsAuthentication || presentation.secondaryAction != nil ? 100 : 80)),
                more.trailingAnchor.constraint(equalTo: row.trailingAnchor), more.widthAnchor.constraint(equalToConstant: 32),
                more.heightAnchor.constraint(equalToConstant: 28), more.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                details.trailingAnchor.constraint(equalTo: more.leadingAnchor, constant: -8), details.widthAnchor.constraint(equalToConstant: 72),
                details.heightAnchor.constraint(equalToConstant: 28), details.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                actionColumn.trailingAnchor.constraint(equalTo: details.leadingAnchor, constant: -8), actionColumn.widthAnchor.constraint(equalToConstant: actionWidth),
                actionColumn.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                title.leadingAnchor.constraint(equalTo: row.leadingAnchor), title.trailingAnchor.constraint(equalTo: actionColumn.leadingAnchor, constant: -12),
                title.topAnchor.constraint(equalTo: row.topAnchor, constant: 12), title.heightAnchor.constraint(equalToConstant: 18),
                identity.leadingAnchor.constraint(equalTo: title.leadingAnchor), identity.trailingAnchor.constraint(equalTo: title.trailingAnchor),
                identity.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3), identity.heightAnchor.constraint(equalToConstant: 16),
                divider.leadingAnchor.constraint(equalTo: row.leadingAnchor), divider.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                divider.bottomAnchor.constraint(equalTo: row.bottomAnchor), divider.heightAnchor.constraint(equalToConstant: 1)
            ])
            if !compactHealthy {
                NSLayoutConstraint.activate([
                    state.leadingAnchor.constraint(equalTo: title.leadingAnchor), state.trailingAnchor.constraint(equalTo: title.trailingAnchor),
                    state.topAnchor.constraint(equalTo: presentation.showsAuthentication ? authentication.bottomAnchor : identity.bottomAnchor, constant: 3),
                    state.heightAnchor.constraint(equalToConstant: 16)
                ])
            }
            if presentation.showsAuthentication {
                NSLayoutConstraint.activate([
                    authentication.leadingAnchor.constraint(equalTo: title.leadingAnchor), authentication.trailingAnchor.constraint(equalTo: title.trailingAnchor),
                    authentication.topAnchor.constraint(equalTo: identity.bottomAnchor, constant: 3), authentication.heightAnchor.constraint(equalToConstant: 16)
                ])
            }
        }
        let caption: String
        if embedded {
            caption = "Managed access renews automatically when connected." +
                (!isLocalWorkstation && remoteRequiresControl ? " Take Control to manage these profiles." : "")
        } else {
            caption = isLocalWorkstation ? "Access renews automatically. Details has checks and sign-in options."
                : remoteRequiresControl ? "Take Control to manage profiles on " + workstationName + ". Sign-in opens on This Mac." : "Profiles run on " + workstationName + ". Browser sign-in opens on This Mac."
        }
        addRow(NSStackView(views: [label(caption)]))
    }

    private func addMenuItem(_ title: String, to menu: NSMenu, enabled: Bool = true, action: @escaping () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(invokeMenuAction(_:)), keyEquivalent: "")
        let id = UUID().uuidString; item.representedObject = id; item.target = self; actions[id] = action
        item.isEnabled = enabled && !pending && canMutate
        menu.addItem(item)
    }
    @objc private func showActions(_ sender: NSButton) { sender.menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender) }
    public func menuWillOpen(_ menu: NSMenu) { trackingMenu = true }
    public func menuDidClose(_ menu: NSMenu) { trackingMenu = false; DispatchQueue.main.async { [weak self] in self?.render() } }
    @objc private func invokeMenuAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }; actions[id]?()
    }
    private func showDetails(_ item: AWSProfilePresentation) {
        detailsID = item.id; detailsSignature = ""
        if embedded {
            rowsSignature = ""; updateSubtitle(); render(); return
        }
        if detailsPanel == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 440),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "AWS Profile Details"; window.isReleasedWhenClosed = false; window.delegate = self
            window.minSize = NSSize(width: 420, height: 360)
            let body = NSStackView(); body.orientation = .vertical; body.alignment = .leading; body.spacing = 12
            body.translatesAutoresizingMaskIntoConstraints = false
            window.contentView!.addSubview(body)
            NSLayoutConstraint.activate([
                body.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
                body.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
                body.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
                body.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -20)
            ])
            detailsPanel = window; detailsBody = body
            if !suppressDetailsPresentationForTesting { panel.addChildWindow(window, ordered: .above) }
            window.setFrameOrigin(NSPoint(x: panel.frame.midX - window.frame.width / 2, y: panel.frame.midY - window.frame.height / 2))
        }
        renderDetails(); if !suppressDetailsPresentationForTesting { detailsPanel?.makeKeyAndOrderFront(nil) }
    }
    private func detailsButton(_ title: String, action: @escaping () -> Void) -> NSButton {
        let value = NSButton(title: title, target: self, action: #selector(invokeDetailsAction(_:)))
        detailsActions[ObjectIdentifier(value)] = action; value.isEnabled = !pending && canMutate
        return value
    }
    @objc private func invokeDetailsAction(_ sender: NSButton) { detailsActions[ObjectIdentifier(sender)]?() }
    private func renderDetails() {
        guard let id = detailsID, let body = detailsBody else { return }
        let rows = AWSProfilePresentation.rows(catalog: catalog)
        let item = rows.first { $0.id == id }
        let sources = Set(catalog["sources"] as? [String] ?? [])
        let detailState: [String: Any] = ["catalog": catalog, "id": id, "pending": pending, "error": actionError ?? "",
            "width": embedded ? view.bounds.width : detailsPanel?.contentView?.frame.width ?? 0, "stale": snapshotStale, "canManage": remoteCanManage, "controlling": remoteControlActive, "requiresControl": remoteRequiresControl, "operations": allowedRemoteOperations.sorted(),
            "usable": item?.usableExpiration() != nil, "network": peerState["awsStatus"] ?? [:]]
        guard let stateData = try? JSONSerialization.data(withJSONObject: detailState, options: [.sortedKeys]) else { return }
        let signature = String(decoding: stateData, as: UTF8.self)
        guard signature != detailsSignature else { return }; detailsSignature = signature
        for view in body.arrangedSubviews { body.removeArrangedSubview(view); view.removeFromSuperview() }
        detailsActions.removeAll()
        func line(_ text: String, identifier: String? = nil) {
            let field = label(text); field.maximumNumberOfLines = 0
            if let identifier { field.identifier = .init(identifier); field.setAccessibilityIdentifier(identifier) }
            body.addArrangedSubview(field); field.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
        guard let item else { line("This profile is no longer available."); return }
        let source = sources.contains(id), receiver = item.isInstalled && !source
        let sourceRecovery = item.needsIncomingSourceRecovery(isSource: source)
        let commandExpiry = source && item.hasLocalProfile && !item.isInstalled ? item.verifiedNativeExpiration() : item.usableExpiration()
        let presentation = item.rowState(isSource: source, sourceStatus: nil, isSigningIn: false)
        let name = NSTextField(labelWithString: item.name); name.font = .systemFont(ofSize: 17, weight: .semibold)
        name.lineBreakMode = .byTruncatingMiddle; name.maximumNumberOfLines = 1; name.toolTip = item.name
        body.addArrangedSubview(name); name.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        line(item.identitySummary)
        line(scoped(presentation.authenticationText))
        let guidance: String
        if sourceRecovery {
            guidance = "Shared access is available from an approved Mac. Use Shared Access to switch this profile from its native sign-in."
        } else if !isLocalWorkstation && commandExpiry != nil && item.sourceCheck.state == "ready" {
            guidance = "Access is ready on " + workstationName + ". Checks and renewals run on that Mac."
        } else if item.status == "Choose Account Again" { guidance = "Different sign-ins provide conflicting identities. Choose the intended account before using this profile." }
        else if receiver && item.sourceCheck.needsSharedRenewal { guidance = item.usableExpiration() == nil ? "Shared credentials are unavailable. Reconnect a providing Mac, then sync access." : "Shared access is available. Check Access verifies it with AWS." }
        else if receiver && item.sourceCheck.state == "signInRequired" { guidance = "Shared access renews on its providing Mac. A local sign-in is optional." }
        else if item.sourceCheck.state == "notChecked" && receiver { guidance = item.usableExpiration() != nil ? "Shared access is ready. Check Access verifies it with AWS." : "Reconnect a providing Mac, then sync access." }
        else if item.sourceCheck.state == "ready" && commandExpiry == nil { guidance = "Access needs another check." }
        else { guidance = item.sourceCheck.guidance }
        line(guidance, identifier: "aws-details-status")
        if let actionError { line(actionError, identifier: "aws-details-action-error") }
        let expiry = sourceRecovery ? item.incomingExpiration : source && !item.isInstalled ? item.sourceCheck.expiration
            : item.available ? item.expiration : (!receiver ? item.sourceCheck.expiration : item.expiration)
        if let expiry, expiry.isFinite {
            line((sourceRecovery ? "Received credentials expire " : "Credentials expire ") + DateFormatter.localizedString(from: Date(timeIntervalSince1970: expiry), dateStyle: .medium, timeStyle: .short), identifier: "aws-details-expiry")
            line("Check Access does not reset expiry.", identifier: "aws-details-expiry-help")
            line(source || receiver ? "AWS sets credential duration. TerminalDB renews managed access automatically when connected." : "AWS sets credential duration. The AWS CLI manages this local profile’s access.")
        }
        if embedded {
            line("AWS commands choose a profile with --profile or AWS_PROFILE.", identifier: "aws-details-profile-scope")
            line("Sign-in expiry is unavailable. AWS may renew access without another browser sign-in.", identifier: "aws-details-auth-expiry")
            if !isLocalWorkstation {
                line(remoteRequiresControl ? "Take Control to manage AWS profiles on " + workstationName + ". Browser sign-in opens on This Mac."
                    : "Profile changes apply on " + workstationName + ". Sign in on This Mac and share access through your approved connection.", identifier: "aws-details-remote-guidance")
            }
        }
        if let checked = item.sourceCheck.checkedAt, checked.isFinite {
            line("Last checked " + DateFormatter.localizedString(from: Date(timeIntervalSince1970: checked), dateStyle: .short, timeStyle: .short))
        }
        if !item.installedNames.isEmpty {
            let aliases = label("Profile names: " + item.installedNames.joined(separator: ", "))
            aliases.maximumNumberOfLines = 3; aliases.lineBreakMode = .byTruncatingMiddle; aliases.toolTip = aliases.stringValue
            body.addArrangedSubview(aliases); aliases.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
        let check = detailsButton(item.sourceCheck.state == "checking" ? "Checking…" : "Check Access") { [weak self] in self?.checkAccess(id) }
        check.identifier = .init("aws-details-check"); check.setAccessibilityIdentifier("aws-details-check")
        check.isEnabled = check.isEnabled && allows(source ? "aws.refresh" : "aws.check") && item.sourceCheck.state != "checking"
        var actions: [NSView] = [check]
        if sourceRecovery {
            let use = detailsButton("Use Shared Access…") { [weak self] in self?.install(item) }
            use.identifier = .init("aws-details-use-shared"); use.isEnabled = use.isEnabled && allows("aws.use")
            actions.append(use)
        }
        let needsSignIn = !receiver && item.sourceCheck.state == "signInRequired"
        if isLocalWorkstation && !sourceRecovery && (needsSignIn || (receiver && item.usableExpiration() == nil)) {
            let signIn = detailsButton("Sign In Here…") { [weak self] in self?.request("aws.signIn.start", ["profileId": id]) }
            signIn.identifier = .init("aws-details-sign-in"); signIn.isEnabled = signIn.isEnabled && (catalog["signInProfile"] as? String ?? "").isEmpty
            actions.append(signIn)
        }
        if embedded && !isLocalWorkstation && !sourceRecovery && (needsSignIn || (receiver && item.usableExpiration() == nil)), localSignInHandler != nil {
            let signIn = detailsButton("Sign In on This Mac…") { [weak self] in self?.requestLocalSignIn(item.id) }
            signIn.isEnabled = !pending && !snapshotStale; signIn.identifier = .init("aws-details-local-sign-in")
            actions.append(signIn)
        }
        let done = detailsButton("Done") { [weak self] in self?.detailsPanel?.close() }
        let controls = NSStackView(views: actions + (embedded ? [] : [NSView(), done])); controls.orientation = .horizontal; controls.spacing = 8
        body.addArrangedSubview(controls); controls.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        if isLocalWorkstation && receiver && item.usableExpiration() == nil {
            let sync = detailsButton("Sync Access") { [weak self] in self?.syncNow() }
            body.addArrangedSubview(sync)
        }
        body.layoutSubtreeIfNeeded()
        if embedded {
            list.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: list.fittingSize.height)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        if !embedded, let window = detailsPanel { window.setContentSize(NSSize(width: window.contentView!.frame.width, height: max(360, body.fittingSize.height + 40))) }
    }
    /// An explicit user action always authenticates on the viewing Mac.
    /// The execution client's target, controller generation and catalog stay intact.
    @objc(beginLocalSignIn:)
    public func beginLocalSignIn(_ profile: NSDictionary) {
        guard active, embedded, !localAuthStarting, !localAuthCancelable, !localAuthMonitoring,
              let data = try? JSONSerialization.data(withJSONObject: profile), data.count <= 16_384,
              let descriptor = try? JSONDecoder().decode(AWSProfileDescriptor.self, from: data),
              (try? descriptor.validate()) != nil else { return }
        localAuthProfileID = descriptor.id; localAuthAttempt = nil; localAuthStarting = true; localAuthObserved = false; localAuthMonitoring = true
        localAuthSubmittedAt = 0; localAuthWasSubmitted = false; localAuthUncertain = false; localAuthStatusPending = false
        localAuthGeneration += 1; Self.localSignInToResume = descriptor.id; Self.localSignInAttemptToResume = nil; Self.localSignInUncertainToResume = false; Self.localSignInAcknowledgedAt = nil
        let attempt = localAuthGeneration
        localAuthSection.isHidden = false; localAuthCancel.isHidden = true
        localAuthBanner.stringValue = "Starting sign-in on This Mac. Access updates only through your approved sharing settings."
        let generation = lifecycle
        var payload: [String: Any] = ["profileId": descriptor.id]
        if descriptor.kind == "sso" { payload["descriptor"] = profile }
        connectLocalAuth { [weak self] in
            guard let self, self.active, self.lifecycle == generation, self.localAuthGeneration == attempt else { return }
            self.localAuthWasSubmitted = true
            self.sendLocalAuth("aws.signIn.start", payload: payload as NSDictionary) { [weak self] result in
                guard let self, self.active, self.lifecycle == generation, self.localAuthGeneration == attempt else { return }
                self.localAuthStarting = false
                if result["uncertain"] as? Bool == true {
                    self.localAuthUncertain = true; Self.localSignInUncertainToResume = true
                    self.localAuthSubmittedAt = Date().timeIntervalSince1970
                    self.localAuthCancelable = false; self.localAuthCancel.isHidden = true
                    self.localAuthBanner.stringValue = "The sign-in request on This Mac was not acknowledged. It may have started; TerminalDB will not repeat it. Checking local status…"
                    self.refreshLocalAuth()
                } else if let error = result["error"] as? String {
                    self.localAuthCancelable = false; self.localAuthMonitoring = false; self.localAuthCancel.isHidden = true
                    self.localAuthBanner.stringValue = error
                    if Self.localSignInToResume == self.localAuthProfileID { Self.localSignInToResume = nil; Self.localSignInAttemptToResume = nil }
                } else {
                    self.localAuthSubmittedAt = Date().timeIntervalSince1970
                    self.localAuthAttempt = (result["signInAttempt"] as? String).flatMap { UUID(uuidString: $0) == nil ? nil : $0 }
                    Self.localSignInAttemptToResume = self.localAuthAttempt
                    Self.localSignInAcknowledgedAt = self.localAuthAttempt == nil ? nil : self.localAuthSubmittedAt
                    self.localAuthCancelable = self.localAuthAttempt != nil; self.localAuthCancel.isHidden = !self.localAuthCancelable
                    self.localAuthBanner.stringValue = "Complete sign-in in your browser on This Mac. Access updates approved Macs when connected; sharing must be enabled on both Macs."
                    self.refreshLocalAuth()
                }
            }
        }
    }

    private func connectLocalAuth(_ completion: @escaping () -> Void) {
        guard active else { return }
        if localAuthRequestForTesting != nil { completion(); return }
        if localAuthClient == nil { localAuthClient = TDBSessionClient() }
        guard let localAuthClient, localAuthClient.workstationID.isEmpty else { return }
        if localAuthClient.connected { completion(); return }
        let generation = lifecycle
        localAuthClient.connect { [weak self] _ in
            guard let self, self.active, self.lifecycle == generation else { return }
            completion()
        }
    }

    private func sendLocalAuth(_ operation: String, payload: NSDictionary, completion: @escaping (NSDictionary) -> Void) {
        guard ["aws.signIn.start", "aws.signIn.cancel", "aws.status"].contains(operation) else { return }
        if let localAuthRequestForTesting { localAuthRequestForTesting(operation, payload, completion); return }
        guard let localAuthClient, localAuthClient.workstationID.isEmpty, localAuthClient.connected else {
            completion(["error": "Reconnect this Mac’s background service to finish sign-in."]); return
        }
        localAuthClient.request(operation, payload: payload, completion: completion)
    }

    private func refreshLocalAuth() {
        guard active, localAuthMonitoring, localAuthProfileID != nil, !localAuthStatusPending,
              localAuthRequestForTesting != nil || localAuthClient?.connected == true else { return }
        localAuthStatusPending = true
        let generation = lifecycle, attempt = localAuthGeneration
        sendLocalAuth("aws.status", payload: [:]) { [weak self] result in
            guard let self, self.active, self.lifecycle == generation, self.localAuthGeneration == attempt else { return }
            self.localAuthStatusPending = false
            self.applyLocalAuthStatus(result)
        }
    }

    private func applyLocalAuthStatus(_ snapshot: NSDictionary) {
        guard localAuthMonitoring, let profileID = localAuthProfileID else { return }
        if snapshot["error"] != nil || snapshot["state"] as? String == "unavailable" {
            if localAuthUncertain {
                localAuthBanner.stringValue = "The sign-in request on This Mac is uncertain. Its status is unavailable; TerminalDB will not repeat it."
                localAuthCancel.isHidden = true
                return
            }
            localAuthBanner.stringValue = "Sign-in status on This Mac is unavailable. Reopen Accounts after reconnecting this Mac’s background service."
            localAuthCancel.isHidden = true
            return
        }
        guard snapshot["state"] as? String == "ready", snapshot["stale"] as? Bool != true,
              let local = snapshot["catalog"] as? [String: Any] else { return }
        let signing = local["signInProfile"] as? String ?? ""
        if localAuthUncertain {
            localAuthCancelable = false; localAuthCancel.isHidden = true
            if !signing.isEmpty {
                localAuthBanner.stringValue = "An AWS sign-in is running on This Mac. The earlier request was not acknowledged, so this view cannot cancel or claim that attempt. TerminalDB will not repeat it."
            } else {
                localAuthBanner.stringValue = "The earlier sign-in request on This Mac is still unconfirmed. No sign-in appears in the latest cached status, but the request may still be pending. TerminalDB will not repeat it."
            }
            return
        }
        if signing == profileID {
            let currentAttempt = local["signInAttempt"] as? String
            if let expected = localAuthAttempt, currentAttempt != expected {
                localAuthCancelable = false; localAuthMonitoring = false; localAuthCancel.isHidden = true
                localAuthBanner.stringValue = "Another sign-in for this profile is running on This Mac. This view does not cancel that attempt."
                return
            }
            localAuthObserved = true; localAuthCancelable = localAuthAttempt != nil
            localAuthBanner.stringValue = "Complete sign-in in your browser on This Mac. Access updates approved Macs when connected; sharing must be enabled on both Macs."
        } else if !signing.isEmpty {
            localAuthCancelable = false; localAuthMonitoring = false
            if Self.localSignInToResume == profileID && Self.localSignInAttemptToResume == localAuthAttempt { Self.localSignInToResume = nil; Self.localSignInAttemptToResume = nil }
            localAuthBanner.stringValue = "Another AWS sign-in is open on This Mac. This view does not cancel that sign-in."
        } else if !localAuthStarting && (localAuthObserved || (localAuthSubmittedAt > 0 && ((snapshot["updatedAt"] as? Double).map { $0.isFinite && $0 >= localAuthSubmittedAt } ?? false))) {
            localAuthCancelable = false; localAuthMonitoring = false
            if Self.localSignInToResume == profileID && Self.localSignInAttemptToResume == localAuthAttempt { Self.localSignInToResume = nil; Self.localSignInAttemptToResume = nil }
            let phase = local["phase"] as? String ?? ""
            if phase.localizedCaseInsensitiveContains("cancel") {
                localAuthBanner.stringValue = "Sign-in on This Mac was cancelled. The execution Mac’s profiles are unchanged."
            } else if phase.localizedCaseInsensitiveContains("fail") || phase.localizedCaseInsensitiveContains("could not") || phase.localizedCaseInsensitiveContains("did not finish") || phase.localizedCaseInsensitiveContains("still needs sign-in") || phase.localizedCaseInsensitiveContains("but") {
                localAuthBanner.stringValue = "Sign-in on This Mac needs attention. Open AWS Access on This Mac to review it."
            } else if !localAuthWasSubmitted && !localAuthObserved {
                localAuthBanner.stringValue = "The sign-in on This Mac is no longer running. Review access on This Mac before relying on renewal."
            } else {
                localAuthBanner.stringValue = "Sign-in on This Mac finished. Access updates approved Macs when connected and sharing is enabled on both Macs."
            }
        }
        localAuthCancel.isHidden = !localAuthCancelable
    }

    @objc private func cancelLocalSignIn() {
        guard active, localAuthCancelable, let profileID = localAuthProfileID, let authAttempt = localAuthAttempt else { return }
        let generation = lifecycle, attempt = localAuthGeneration
        sendLocalAuth("aws.signIn.cancel", payload: ["profileId": profileID, "signInAttempt": authAttempt]) { [weak self] result in
            guard let self, self.active, self.lifecycle == generation, self.localAuthGeneration == attempt else { return }
            if result["error"] != nil { self.localAuthBanner.stringValue = "Sign-in on This Mac could not be cancelled. Check its current browser sign-in." }
            else {
                self.localAuthCancelable = false; self.localAuthMonitoring = false; self.localAuthStatusPending = false; self.localAuthCancel.isHidden = true
                self.localAuthGeneration += 1
                if Self.localSignInToResume == self.localAuthProfileID { Self.localSignInToResume = nil; Self.localSignInAttemptToResume = nil }
                self.localAuthBanner.stringValue = "Sign-in on This Mac is no longer running."
            }
        }
    }

    @objc private func showLocalSharing() {
        // Opening a manager is explicit; it does not approve a peer or profile.
        Self.present()
        Self.current?.openSharing()
    }

    private func requestLocalSignIn(_ id: String) {
        guard embedded, !isLocalWorkstation, clientMatchesWorkstation, !snapshotStale, !pending,
              let item = AWSProfilePresentation.rows(catalog: catalog).first(where: { $0.id == id }) else { return }
        let receiver = item.isInstalled && !(catalog["sources"] as? [String] ?? []).contains(id)
        guard !recoversNativeSource(item), (!receiver && item.sourceCheck.state == "signInRequired") || (receiver && item.usableExpiration() == nil),
              let data = try? JSONEncoder().encode(item.descriptor),
              let profile = try? JSONSerialization.jsonObject(with: data) as? NSDictionary else { return }
        localSignInHandler?(profile)
    }

    private func checkAccess(_ id: String) {
        guard AWSProfilePresentation.rows(catalog: catalog).contains(where: { $0.id == id }) else { return }
        let source = (catalog["sources"] as? [String] ?? []).contains(id)
        request(source ? "aws.refresh" : "aws.check", ["profileId": id, "manual": true])
    }
    @objc private func showHelp() {
        let alert = NSAlert(); alert.messageText = "Shared AWS Access"
        alert.informativeText = "Only selected profiles are shared with explicitly approved Macs. Browser sign-ins remain on their original Mac; each receiver keeps temporary access until AWS’s expiry.\n\nOne SSO sign-in renews all profiles using that same session on This Mac. Only profiles you choose are shared.\n\nYou can sign in on any Mac. Profiles shared while away arrive automatically after LAN or VPN reconnects. Disabling sharing stops future transfers; revoke access in AWS when immediate termination is required. Claude sharing is configured separately."
        alert.addButton(withTitle: "Done"); if let ownerWindow { alert.beginSheetModal(for: ownerWindow) }
    }
    private func canInstallImmediately(_ item: AWSProfilePresentation, suggestedName: String? = nil) -> Bool {
        let occupied = Set(catalog["localProfileNames"] as? [String] ?? [])
        let suggested = suggestedName ?? item.suggestedName(rows: profileRows, occupiedNames: occupied)
        return !recoversNativeSource(item) && suggestedName == nil && !item.hasLocalProfile && !item.isInstalled && suggested == item.descriptor.name && !occupied.contains(suggested)
    }
    private func install(_ item: AWSProfilePresentation, suggestedName: String? = nil) {
        guard allows("aws.use") else { return }
        let sourceRecovery = recoversNativeSource(item)
        let name = item.name, suggested = suggestedName ?? item.suggestedName(rows: profileRows, occupiedNames: Set(catalog["localProfileNames"] as? [String] ?? []))
        if canInstallImmediately(item, suggestedName: suggestedName) {
            request("aws.use", ["profileId": item.id, "targetName": suggested, "replaceSource": false])
            return
        }
        if let confirmInstallForTesting { confirmInstallForTesting(item.id, suggested); return }
        let alert = NSAlert()
        alert.messageText = sourceRecovery ? "Use shared AWS access on " + workstationName + "?" : "Use \(name) on " + workstationName + "?"
        let context: String
        if sourceRecovery {
            let providers = item.incomingSourceNames.isEmpty ? "an approved Mac" : item.incomingSourceNames.joined(separator: ", ")
            context = "Use access from " + providers + " for " + name + ". TerminalDB backs up the current settings and stops renewing this profile’s original sign-in. Other AWS profiles stay unchanged."
        } else if suggestedName != nil {
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
        field.setAccessibilityLabel("AWS profile name on " + workstationName); alert.accessoryView = field
        alert.addButton(withTitle: "Use Profile"); alert.addButton(withTitle: "Cancel")
        guard let ownerWindow else { return }
        alert.beginSheetModal(for: ownerWindow) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.confirmInstallation(item.id, targetName: field.stringValue, stopSource: sourceRecovery)
        }
    }

    private func confirmInstallation(_ id: String, targetName: String, stopSource: Bool) {
        guard let item = AWSProfilePresentation.rows(catalog: catalog).first(where: { $0.id == id }) else { return }
        if stopSource && !recoversNativeSource(item) {
            actionError = "Shared access changed. Check this profile again before switching it."; renderDetails(); return
        }
        var payload: [String: Any] = ["profileId": id, "targetName": targetName,
            "replaceSource": stopSource || item.localNames.contains(targetName)]
        if stopSource { payload["stopSource"] = true }
        request("aws.use", payload)
    }

    private func remove(id: String, name: String) {
        guard allows("aws.remove") else { return }
        let alert = NSAlert(); alert.messageText = "Remove \(name) from TerminalDB on " + workstationName + "?"
        alert.informativeText = scoped("This stops sharing this AWS access from This Mac and removes its TerminalDB-managed profile aliases. Their original settings are restored when safe. Other AWS profiles stay unchanged. Temporary credentials already copied to other Macs remain valid until AWS expires or revokes them.")
        alert.addButton(withTitle: "Remove Profile"); alert.addButton(withTitle: "Cancel")
        guard let ownerWindow else { return }
        alert.beginSheetModal(for: ownerWindow) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.request("aws.remove", ["profileId": id]) }
        }
    }

    private func request(_ operation: String, _ payload: [String: Any]) {
        guard allows(operation) else { return }
        if let requestForTesting { requestForTesting(operation, payload); return }
        guard !pending else { return }; pending = true; rowsSignature = ""; actionError = nil; render(); renderDetails()
        status.stringValue = operation == "aws.signIn.start" ? "Starting AWS sign-in in your browser on This Mac…" : "Updating AWS access…"
        let generation = lifecycle
        host.request(operation, payload: payload as NSDictionary) { [weak self] result in
            guard let self, self.lifecycle == generation, self.clientMatchesWorkstation else { return }; self.pending = false; self.rowsSignature = ""
            self.applyActionResult(operation, result: result)
            self.render(); self.renderDetails()
            if self.isLocalWorkstation && self.agent.connected && operation != "aws.check" && operation != "aws.refresh" { self.agent.request("aws.sync.now", payload: [:]) { _ in } }
            self.refresh()
        }
    }
    private func applyActionResult(_ operation: String, result: NSDictionary) {
        let checking = operation == "aws.check" || operation == "aws.refresh"
        actionError = result["error"] as? String
        if actionError == nil && checking && result["accepted"] as? Bool == false { actionError = "Access checks are busy. Try Check Access again in a moment." }
        status.stringValue = actionError ?? (checking ? "" : "Saved. Approved Macs sync automatically over your LAN or VPN.")
    }

    @objc private func syncMacChanged(_ sender: NSButton) {
        guard isLocalWorkstation, canMutate else { return }
        guard let id = choices.first(where: { $0.1 === sender })?.0 else { return }
        var desired = syncDraft ?? Set(peerState["awsPeers"] as? [String] ?? [])
        if sender.state == .on { desired.insert(id) } else { desired.remove(id) }
        syncDraft = desired
        actionError = nil
        saveSync()
    }
    private func saveSync() {
        guard isLocalWorkstation, canMutate, !syncSaving, let desired = syncDraft else { return }
        syncSaving = true
        let peers = Array(desired).sorted()
        let generation = lifecycle
        agent.request("aws.sync.configure", payload: ["peers": peers]) { [weak self] result in
            guard let self, self.lifecycle == generation, self.clientMatchesWorkstation else { return }
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
        guard isLocalWorkstation, canMutate else { return }
        if let syncForTesting { syncForTesting(); return }
        actionError = nil
        let generation = lifecycle
        agent.request("aws.sync.now", payload: [:]) { [weak self] result in
            guard let self, self.lifecycle == generation, self.clientMatchesWorkstation else { return }
            self.actionError = result["error"] as? String
            self.status.stringValue = result["error"] as? String ?? "Checking your approved Macs for updated access…"
            self.refresh()
        }
    }
    @objc private func cancelSignIn() { request("aws.signIn.cancel", [:]) }
    private func prepareClose() -> Bool {
        guard !syncSaving, syncDraft == nil else {
            closeAfterSync = true; status.stringValue = "Saving AWS sync settings…"; return false
        }
        return true
    }
    public func windowShouldClose(_ sender: NSWindow) -> Bool { sender === detailsPanel ? true : prepareClose() }
    public func windowDidResize(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === detailsPanel { renderDetails() }
    }
    @objc private func closePanel() { if prepareClose() { panel.close() } }
    public func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === detailsPanel {
            detailsPanel = nil; detailsBody = nil; detailsID = nil; detailsActions.removeAll(); return
        }
        detailsPanel?.close()
        stop(); Self.current = nil
    }
}
