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
        didSet { rowsSignature = ""; render() }
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
    private let backButton = NSButton(title: "Profiles", target: nil, action: nil)
    private let pageTitle = NSTextField(labelWithString: "")
    private let pageHeader = NSStackView()
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
    private var sessionRows: [AWSSessionPresentation] = []
    private var confirmRestartForTesting: ((String, Bool) -> Void)?
    private var alertForTesting: ((String, String) -> Void)?
    private var clockForTesting: Date?
    private var now: Date { clockForTesting ?? Date() }

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
            let clock = Date(timeIntervalSince1970: expiration - 3600)
            let sessionID = String(repeating: "a", count: 64)
            func session(_ state: String, end: Double? = nil, restart: Bool = true, source: String = "default") -> [[String: Any]] {
                var value: [String: Any] = ["id": sessionID, "name": "workspace-sso", "startURL": "https://example.awsapps.com/start",
                    "profileIds": [engineering.id, production.id, matchingNative.id, migrated.id].sorted(), "state": state,
                    "duration": 28800.0, "durationSource": source, "canRestart": restart]
                if let end { value["signedInAt"] = end - 28800; value["expectedEnd"] = end }
                if state == "signedOut" { value["endedAt"] = clock.timeIntervalSince1970 - 600 }
                return [value]
            }
            var sessionBase = base; sessionBase["ssoSessions"] = session("signedOut")
            let view = TDBAWSAccessPanel(); view.hostConnectionForTesting = true; defer { view.panel.close() }
            view.clockForTesting = clock
            view.catalog = sessionBase; view.peerState = ["awsPeers": ["fixture-peer"]]
            view.panel.contentView?.layoutSubtreeIfNeeded(); view.render()
            func descendant(_ root: NSView, _ identifier: String) -> NSView? {
                if root.identifier?.rawValue == identifier { return root }
                for child in root.subviews { if let value = descendant(child, identifier) { return value } }
                return nil
            }
            func allSubviews(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(allSubviews) }
            func row(_ name: String, in panel: TDBAWSAccessPanel? = nil) throws -> NSView {
                guard let value = (panel ?? view).list.arrangedSubviews.first(where: { item in
                    (descendant(item, "aws-profile-name") as? NSTextField)?.stringValue == name
                }) else { throw PeerFailure("AWS interface: missing fixture row") }
                return value
            }
            func control(_ name: String, _ identifier: String = "aws-profile-primary", in panel: TDBAWSAccessPanel? = nil) throws -> NSView {
                guard let value = descendant(try row(name, in: panel), identifier) else { throw PeerFailure("AWS interface: missing fixture control " + identifier) }
                return value
            }
            func primary(_ name: String, in panel: TDBAWSAccessPanel? = nil) -> NSButton? {
                (try? row(name, in: panel)).flatMap { descendant($0, "aws-profile-primary") as? NSButton }
            }
            func statusText(_ name: String, in panel: TDBAWSAccessPanel? = nil) throws -> String {
                (try control(name, "aws-profile-state", in: panel) as? NSTextField)?.stringValue ?? ""
            }
            func menu(_ name: String, in panel: TDBAWSAccessPanel? = nil) throws -> NSMenu {
                guard let value = (try control(name, "aws-profile-actions", in: panel) as? NSButton)?.menu else { throw PeerFailure("AWS interface: missing row menu") }
                return value
            }
            func perform(_ menu: NSMenu, _ title: String) throws {
                guard let index = menu.items.firstIndex(where: { $0.title == title }) else { throw PeerFailure("AWS interface: missing menu item " + title) }
                try check(menu.items[index].isEnabled, "menu item enabled: " + title)
                menu.performActionForItem(at: index)
            }
            func header(_ panel: TDBAWSAccessPanel? = nil) -> NSView? {
                (panel ?? view).list.arrangedSubviews.first { $0.identifier?.rawValue == "aws-session-row" }
            }
            func headerText(_ identifier: String, _ panel: TDBAWSAccessPanel? = nil) -> String {
                header(panel).flatMap { descendant($0, identifier) as? NSTextField }?.stringValue ?? ""
            }
            func headerButton(_ panel: TDBAWSAccessPanel? = nil) -> NSButton? { header(panel).flatMap { descendant($0, "aws-session-primary") as? NSButton } }

            for width in [600.0, 700.0, 1000.0] {
                view.panel.setContentSize(NSSize(width: width, height: 560))
                guard let content = view.panel.contentView else { return false }
                content.layoutSubtreeIfNeeded(); view.list.layoutSubtreeIfNeeded()
                let rows = view.list.arrangedSubviews.filter { $0.identifier?.rawValue == "aws-profile-row" }
                try check(rows.count == 8, "fixture row count")
                try check(view.list.arrangedSubviews.filter { $0.identifier?.rawValue == "aws-session-row" }.count == 1, "one header per SSO session")
                let clip = view.scroll.contentView.convert(view.scroll.contentView.bounds, to: content)
                var columnX: CGFloat?
                func rect(_ item: NSView) -> NSRect { item.superview!.convert(item.alignmentRect(forFrame: item.frame), to: content) }
                for row in rows + [header()!] {
                    let session = row.identifier?.rawValue == "aws-session-row"
                    guard let title = descendant(row, session ? "aws-session-state" : "aws-profile-name") as? NSTextField,
                          let state = descendant(row, session ? "aws-session-detail" : "aws-profile-state") as? NSTextField,
                          let more = descendant(row, session ? "aws-session-actions" : "aws-profile-actions") else { return false }
                    let nameRect = rect(title), stateRect = rect(state), moreRect = rect(more)
                    try check(descendant(row, "aws-profile-details") == nil, "rows have no Details button")
                    try check(nameRect.width >= 150 && nameRect.height >= 16 && stateRect.height >= 14 && !nameRect.intersects(stateRect), "row text geometry at width \(width)")
                    try check(moreRect.maxX <= clip.maxX + 1 && nameRect.minX >= clip.minX - 1 && state.maximumNumberOfLines == 1, "row bounds at width \(width)")
                    if let action = descendant(row, session ? "aws-session-primary" : "aws-profile-primary"), action is NSButton {
                        let actionRect = rect(action)
                        try check(nameRect.maxX <= actionRect.minX - 8 && stateRect.maxX <= actionRect.minX - 8 && actionRect.maxX <= moreRect.minX - 4, "action column geometry at width \(width)")
                        try check(columnX.map { abs($0 - actionRect.maxX) < 1 } ?? true, "actions align at width \(width)")
                        columnX = actionRect.maxX
                    }
                    if !session, let identity = descendant(row, "aws-profile-identity") as? NSTextField {
                        let identityRect = rect(identity)
                        try check(!nameRect.intersects(identityRect) && !identityRect.intersects(stateRect) && identity.maximumNumberOfLines == 1 && identity.font?.pointSize == 12 && title.font?.pointSize == 14, "identity geometry")
                    }
                }
            }
            try check(!allSubviews(view.view).compactMap { ($0 as? NSButton)?.title }.contains("Details"), "no Details buttons anywhere")

            // A signed-out session owns one Sign In for all of its profiles.
            try check(headerText("aws-session-state") == "Signed out" && headerText("aws-session-detail").contains("Sign in to renew 3 profiles"), "signed-out session header")
            try check(headerButton()?.title == "Sign In" && headerButton()?.isEnabled == true, "sign in is a first-class header button")
            var requested: [(String, [String: Any])] = [], confirmations: [(String, String)] = [], restarts: [(String, Bool)] = [], alerts: [String] = []
            var syncRequests = 0
            view.requestForTesting = { requested.append(($0, $1)) }
            view.confirmInstallForTesting = { confirmations.append(($0, $1)) }
            view.confirmRestartForTesting = { restarts.append(($0, $1)) }
            view.alertForTesting = { title, _ in alerts.append(title) }
            view.syncForTesting = { syncRequests += 1 }
            headerButton()?.performClick(nil)
            try check(requested.last?.0 == "aws.signIn.start" && requested.last?.1["profileId"] as? String == [engineering.id, production.id, matchingNative.id].sorted { a, b in
                let rows = AWSProfilePresentation.rows(catalog: sessionBase); return rows.firstIndex { $0.id == a }! < rows.firstIndex { $0.id == b }! }.first && requested.last?.1["restart"] == nil, "header sign-in routes a plain sign-in for the session")
            for name in ["engineering", "production", "native-match"] {
                try check(primary(name)?.title != "Sign In" && primary(name)?.title != "Sign In Again", "grouped rows never repeat sign-in")
            }
            try check(try statusText("production").hasPrefix("Access until ") && (try control("production", "aws-profile-state") as? NSTextField)?.textColor == .systemOrange, "signed-out source shows when its issued access ends")
            try check(try statusText("engineering") == "Expired · sign in above to renew", "signed-out profile without access says expired")
            try check(try statusText("migrated").hasPrefix("Ready"), "receiver is not grouped under this Mac's sign-in")
            try check((try control("production", "aws-profile-identity") as? NSTextField)?.stringValue == "222222222222 · Developer · Shared from This Mac", "identity line carries context")

            // Signed in: the end time is on the main pane with Extend.
            view.catalog["ssoSessions"] = session("signedIn", end: clock.timeIntervalSince1970 + 3 * 3600)
            view.catalog["sourceChecks"] = [production.id: ["state": "ready", "checkedAt": clock.timeIntervalSince1970 - 60, "expiresAt": expiration]]; view.render()
            let endText = AWSSessionPresentation.moment(clock.timeIntervalSince1970 + 3 * 3600, now: clock)
            try check(headerText("aws-session-state") == "Signed in until " + endText, "signed-in header shows end time")
            try check(headerText("aws-session-detail") == "3 h left · renews 3 profiles", "signed-in header shows time left")
            try check(header().flatMap { descendant($0, "aws-session-state") as? NSTextField }?.textColor == .labelColor, "healthy session is not orange")
            try check(headerButton()?.title == "Extend…", "signed-in session offers Extend")
            headerButton()?.performClick(nil)
            try check(restarts.last?.0 == sessionID && restarts.last?.1 == true, "Extend confirms an explicit session restart")
            try check(try statusText("production") == "Ready · Renews automatically", "healthy grouped source keeps Ready")
            try check(try statusText("engineering") == "Not shared" && primary("engineering")?.title == "Share Access", "unshared signed-in profile says Not shared")
            guard let sessionMenu = (header().flatMap { descendant($0, "aws-session-actions") } as? NSButton)?.menu,
                  let lengths = sessionMenu.items.first(where: { $0.title == "Session Length" })?.submenu else { return false }
            try check(lengths.items.first?.title == "Automatic (8 hours (AWS default))" && lengths.items.first?.state == .on, "automatic length is the default")
            try perform(lengths, "12 hours")
            try check(requested.last?.0 == "aws.session.configure" && requested.last?.1["sessionId"] as? String == sessionID && requested.last?.1["duration"] as? Double == 43200, "custom session length routing")
            try perform(lengths, "Automatic (8 hours (AWS default))")
            try check(requested.last?.0 == "aws.session.configure" && requested.last?.1["duration"] == nil, "automatic length resets")
            try perform(sessionMenu, "Sign In Without Ending Session")
            try check(requested.last?.0 == "aws.signIn.start" && requested.last?.1["restart"] == nil, "plain re-sign-in stays available")
            view.catalog["ssoSessions"] = session("signedIn", end: clock.timeIntervalSince1970 + 3 * 3600, source: "custom"); view.render()
            let customLengths = (header().flatMap { descendant($0, "aws-session-actions") } as? NSButton)?.menu?.items.first { $0.title == "Session Length" }?.submenu
            try check(customLengths?.items.first { $0.title == "8 hours" }?.state == .on && customLengths?.items.first?.state == .off, "custom length is checked")
            view.catalog["ssoSessions"] = session("signedIn", end: clock.timeIntervalSince1970 + 20 * 60); view.render()
            try check(header().flatMap { descendant($0, "aws-session-state") as? NSTextField }?.textColor == .systemOrange && headerText("aws-session-detail").hasPrefix("20 min left"), "ending soon is highlighted")
            view.catalog["ssoSessions"] = session("signedIn", end: clock.timeIntervalSince1970 - 60); view.render()
            try check(headerText("aws-session-state") == "Session may have ended" && headerButton()?.title == "Sign In", "passed estimate offers Sign In")
            view.catalog["ssoSessions"] = session("signedIn", restart: false); view.render()
            try check(headerText("aws-session-state") == "Signed in" && headerButton()?.title == "Sign In Again…", "unknown start still offers sign in again")
            headerButton()?.performClick(nil)
            try check(restarts.last?.1 == false, "sign in again without restart support is not a restart")
            view.catalog["ssoSessions"] = session("signingIn"); view.catalog["signInProfile"] = production.id
            view.catalog["signInProfiles"] = [engineering.id, production.id]; view.render()
            try check(headerText("aws-session-state") == "Signing in…" && headerButton()?.title == "Cancel", "signing-in session offers Cancel")
            try check(try statusText("production") == "Signing in…", "row sign-in progress")
            headerButton()?.performClick(nil)
            try check(requested.last?.0 == "aws.signIn.cancel", "header cancel routing")

            // Older execution Macs do not publish sessions. Rows keep their own sign-in.
            view.catalog = base; view.render()
            try check(header() == nil && primary("production")?.title == "Sign In", "fallback rows keep direct sign-in")
            primary("production")?.performClick(nil)
            try check(requested.last?.0 == "aws.signIn.start" && requested.last?.1["profileId"] as? String == production.id, "fallback sign-in routing")
            try check(try statusText("production") == "Ready · Sign in to keep renewal working", "fallback keeps renewal warning")

            view.catalog = sessionBase; view.render()
            try check(primary("engineering")?.title == "Share Access" && (try menu("engineering")).items.contains { $0.title == "Share This Mac’s Access" } == false, "share is direct and not duplicated")
            primary("engineering")?.performClick(nil)
            try check(requested.last?.0 == "aws.source.enable" && requested.last?.1["profileId"] as? String == engineering.id, "share routing")
            try perform(try menu("engineering"), "Check Access")
            try check(requested.last?.0 == "aws.check" && requested.last?.1["profileId"] as? String == engineering.id && requested.last?.1["manual"] as? Bool == true, "local check is nonpublishing")
            try perform(try menu("production"), "Check Access")
            try check(requested.last?.0 == "aws.refresh" && requested.last?.1["profileId"] as? String == production.id, "source check routing")
            try check((try menu("production")).items.contains { $0.title.hasPrefix("Last checked ") }, "menu shows last check time")
            try check((try menu("production")).items.contains { $0.title == "Copy Profile Name" }, "profile name can be copied")
            try check(primary(incoming.name)?.title == "Use on This Mac", "one-click import label")
            try check(primary("native-match")?.title == "Use on This Mac…", "native migration label indicates confirmation")
            try check(primary("occupied")?.title == "Use on This Mac…", "collision label indicates confirmation")
            primary(incoming.name)?.performClick(nil)
            try check(requested.last?.0 == "aws.use" && requested.last?.1["profileId"] as? String == incoming.id && requested.last?.1["targetName"] as? String == incoming.name && requested.last?.1["replaceSource"] as? Bool == false, "fresh use is one click")
            try check(confirmations.isEmpty, "fresh import avoids a redundant modal")
            let requestCount = requested.count
            primary("native-match")?.performClick(nil)
            try check(requested.count == requestCount && confirmations.last?.0 == matchingNative.id && confirmations.last?.1 == "native-match", "native migration requires confirmation")
            primary("occupied")?.performClick(nil)
            try check(requested.count == requestCount && confirmations.last?.0 == collision.id && confirmations.last?.1 != "occupied", "name collision requires alias confirmation")
            try check(primary("offline")?.title == "Sync Now", "unavailable receiver sync action")
            primary("offline")?.performClick(nil)
            try check(syncRequests == 1, "sync routing")
            try perform(try menu("offline"), "Sign In Here…")
            try check(requested.last?.0 == "aws.signIn.start" && requested.last?.1["profileId"] as? String == offline.id, "optional receiver sign-in lives in the menu")
            try perform(try menu("offline"), "Check Access")
            try check(requested.last?.0 == "aws.check" && requested.last?.1["profileId"] as? String == offline.id, "receiver check routing")
            try check(primary("conflict")?.title == "Review…", "conflict review action")
            primary("conflict")?.performClick(nil)
            try check(alerts.last == "conflict needs review", "review explains the conflict")

            // An installed receiver remains ready even when retained native
            // SSO metadata is expired, missing or unreadable.
            for status in ["expired", "missing", "unknown", "current"] {
                view.catalog["authentication"] = [migrated.id: ["state": status, "sessionName": "workspace-sso"]]
                view.render()
                try check(primary("migrated") == nil && (try statusText("migrated")).hasPrefix("Ready"), "receiver ready label")
                try check((try control("migrated", "aws-profile-identity") as? NSTextField)?.stringValue.hasSuffix("From Fixture Mac") == true, "receiver origin")
                try check((try menu("migrated")).items.contains { $0.title == "Sign In Here…" } && primary("migrated") == nil, "optional receiver sign-in stays in the menu, never a row button")
            }
            let readyMenu = try menu("migrated")
            let beforeReuse = requested.count
            try perform(readyMenu, "Share This Mac’s Access")
            try check(requested.count == beforeReuse + 1 && requested.last?.0 == "aws.source.enable" && requested.last?.1["profileId"] as? String == migrated.id, "ready receiver can share its native sign-in through the menu")
            view.catalog = sessionBase
            view.catalog["sourceChecks"] = [migrated.id: ["state": "checkFailed", "needsSharedRenewal": true]]
            var missingAccounts = base["accounts"] as! [[String: Any]]
            for index in missingAccounts.indices where missingAccounts[index]["profileId"] as? String == migrated.id { missingAccounts[index]["available"] = false }
            view.catalog["accounts"] = missingAccounts; view.render()
            try check(primary("migrated")?.title == "Sync Now", "missing receiver credentials retain sync recovery")
            view.catalog["accounts"] = base["accounts"]; view.render()
            try check(primary("migrated") == nil && (try statusText("migrated")).hasPrefix("Ready"), "fresh shared credentials restore Ready without Check Access")
            view.catalog = sessionBase; view.catalog["ssoSessions"] = session("signedIn", end: clock.timeIntervalSince1970 + 3600)
            view.catalog["sourceChecks"] = [production.id: ["state": "checking", "expiresAt": expiration]]; view.render()
            try check(try statusText("production") == "Ready · Renews automatically", "automatic renewal keeps healthy access ready")
            try check((try menu("production")).items.first?.title == "Checking Access…" && (try menu("production")).items.first?.isEnabled == false, "menu shows active checking")
            for (name, id) in [("production", production.id), ("engineering", engineering.id)] {
                for (failure, prefix) in [("networkUnavailable", ""), ("accessDenied", "Access denied"), ("checkFailed", "Couldn’t check access")] {
                    view.catalog["sourceChecks"] = [id: ["state": failure]]; view.render()
                    try check(primary(name)?.title != "Sign In" && headerButton()?.title == "Extend…", "non-authentication failures do not invite sign-in")
                    if !prefix.isEmpty { try check((try statusText(name)).hasPrefix(prefix), "failure status is inline: " + failure) }
                }
            }
            view.catalog = base; view.peerState = ["awsPeers": []]; view.render()
            guard let choose = allSubviews(view.list).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Choose Macs" }) else { return false }
            choose.performClick(nil)
            try check(view.tabs.selectedSegment == 1, "source setup opens Sharing")
            view.catalog = [:]; view.tabs.selectedSegment = 0; view.render()
            guard let setup = allSubviews(view.list).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Set Up Sharing" }) else { return false }
            setup.performClick(nil)
            try check(view.tabs.selectedSegment == 1, "empty setup opens Sharing")

            // Session wording is deterministic.
            let wording = AWSSessionPresentation.sessions(catalog: ["ssoSessions": session("signedIn", end: clock.timeIntervalSince1970 + 5400, source: "learned")])
            try check(wording.first?.lengthDescription == "8 hours (measured)" && AWSSessionPresentation.length(27000) == "7 hours 30 min" && AWSSessionPresentation.length(604800) == "7 days", "session length wording")
            try check(AWSSessionPresentation.remaining(5400) == "1 h 30 min" && AWSSessionPresentation.remaining(59) == "1 min", "remaining wording")
            try check(AWSSessionPresentation.moment(clock.timeIntervalSince1970 - 86400, now: clock).hasPrefix("yesterday "), "relative day wording")
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
                    guard let name = descendant(row, "aws-profile-name"), let more = descendant(row, "aws-profile-actions") else { return false }
                    func rect(_ child: NSView) -> NSRect { child.superview!.convert(child.alignmentRect(forFrame: child.frame), to: embedded.view) }
                    let n = rect(name), m = rect(more)
                    try check(n.width >= 140 && n.maxX <= m.minX - 8 && m.maxX <= clip.maxX + 1, "embedded columns fit at width \(width)")
                    if let primary = descendant(row, "aws-profile-primary") as? NSButton {
                        let a = rect(primary)
                        try check(n.maxX <= a.minX - 8 && a.maxX <= m.minX - 4, "embedded action column at width \(width)")
                    }
                }
            }
            var healthyEmbedded = base
            healthyEmbedded["sourceChecks"] = [production.id: ["state": "ready", "expiresAt": expiration]]
            embedded.applyStatusSnapshot(["catalog": healthyEmbedded, "state": "ready", "stale": false])
            try check((try statusText("production", in: embedded)) == "Ready · Renews automatically" && primary("production", in: embedded) == nil, "healthy embedded source keeps Ready without a button")
            embedded.view.layoutSubtreeIfNeeded(); embedded.list.layoutSubtreeIfNeeded()
            try check(abs((try row("production", in: embedded)).frame.height - 74) < 1, "embedded rows use the compact three-line height")
            try check((try control("migrated", "aws-profile-identity", in: embedded) as? NSTextField)?.stringValue.hasSuffix("From Fixture Mac") == true, "healthy embedded receiver keeps concise provenance")
            let embeddedCaptions = allSubviews(embedded.list).compactMap { ($0 as? NSTextField)?.stringValue }
            try check(embeddedCaptions.filter { $0 == "Managed access renews automatically when connected." }.count == 1 && !embeddedCaptions.contains { $0.contains("Details") }, "embedded list has one short renewal caption")
            var deniedEmbedded = healthyEmbedded
            deniedEmbedded["sourceChecks"] = [production.id: ["state": "accessDenied", "expiresAt": expiration]]
            embedded.applyStatusSnapshot(["catalog": deniedEmbedded, "state": "ready", "stale": false])
            try check((try statusText("production", in: embedded)).hasPrefix("Access denied") && (try control("production", "aws-profile-state", in: embedded) as? NSTextField)?.toolTip?.contains("permissions") == true, "permission failures keep their full guidance")
            var sessionEmbedded = base; sessionEmbedded["ssoSessions"] = session("signedOut")
            embedded.applyStatusSnapshot(["catalog": sessionEmbedded, "state": "ready", "stale": false])
            try check(headerButton(embedded)?.title == "Sign In" && embeddedRequests.isEmpty, "rendering never submits provider work")
            try perform(try menu("production", in: embedded), "Check Access")
            try check(embeddedRequests == ["aws.refresh"], "only explicit embedded Check Access submits provider work")
            try check(embedded.pageHeader.isHidden && embedded.backButton.isHidden && !embedded.sharingButton.isHidden, "profiles page has no Back button")
            embedded.openSharing()
            try check(!embedded.pageHeader.isHidden && !embedded.backButton.isHidden && embedded.sharingButton.isHidden && embedded.pageTitle.stringValue == "AWS Sharing", "Sharing is a secondary page")
            embedded.view.layoutSubtreeIfNeeded()
            let backFrame = embedded.backButton.convert(embedded.backButton.bounds, to: embedded.view), scrollFrame = embedded.scroll.convert(embedded.scroll.bounds, to: embedded.view)
            try check(backFrame.minY >= scrollFrame.maxY - 1 || backFrame.maxY <= scrollFrame.minY + 1, "Back sits outside the list")
            try check(embedded.view.isFlipped ? backFrame.maxY <= scrollFrame.minY + 1 : backFrame.minY >= scrollFrame.maxY - 1, "Back sits above the list, not at the bottom")
            embedded.backToProfiles()
            try check(embedded.tabs.selectedSegment == 0 && embedded.backButton.isHidden, "Back returns to AWS profiles")
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
            try check(remote.subtitle.stringValue.contains("Office Mac") && remote.sharingButton.isHidden, "remote scope has no local sharing page")
            try check((try menu("production", in: remote)).items.first { $0.title == "Check Access" }?.isEnabled == false, "remote Check Access is disabled until remote mutations are supported")
            try check(primary("production", in: remote)?.title == "Sign In Here…", "remote fallback row offers sign-in on This Mac")
            remote.request("aws.signIn.start", ["profileId": production.id]); remote.checkAccess(production.id)
            remote.install(AWSProfilePresentation.rows(catalog: base).first { $0.id == incoming.id }!); remote.syncNow()
            try check(remoteMutations == 0, "all remote mutation entry points reject without local fallback")
            primary("production", in: remote)?.performClick(nil)
            try check(localSignIns == 1 && remoteMutations == 0, "explicit viewing-Mac sign-in callback does not mutate the remote Mac")
            var remoteSession = base; remoteSession["ssoSessions"] = session("signedOut")
            remote.applyStatusSnapshot(["catalog": remoteSession, "state": "ready", "stale": false])
            try check(headerButton(remote)?.title == "Sign In Here…" && primary("production", in: remote) == nil, "remote session header owns sign-in on This Mac")
            headerButton(remote)?.performClick(nil)
            try check(localSignIns == 2 && remoteMutations == 0, "remote header sign-in targets the profile that needs it")
            try check((header(remote).flatMap { descendant($0, "aws-session-actions") } as? NSButton)?.menu?.items.isEmpty != false, "remote session length is managed on that Mac")
            var healthyRemote = base; healthyRemote["sourceChecks"] = [production.id: ["state": "ready"]]
            remote.applyStatusSnapshot(["catalog": healthyRemote, "state": "ready", "stale": false])
            try check(primary("production", in: remote) == nil, "healthy remote access does not invite login because cached SSO metadata is expired")
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
            try check(useRecovery.title == "Use Shared Access…", "native source recovery offers shared-provider handoff rather than another sign-in or false Ready")
            useRecovery.performClick(nil)
            try check(recoveryConfirmations == 1 && recoveryRequests.isEmpty, "source handoff always requires explicit migration confirmation")
            recoveryPanel.confirmInstallation(production.id, targetName: "production", stopSource: true)
            try check(recoveryRequests.count == 1 && recoveryRequests[0].0 == "aws.use" && recoveryRequests[0].1["stopSource"] as? Bool == true && recoveryRequests[0].1["replaceSource"] as? Bool == true, "only confirmed source recovery sends the scoped stopSource request")
            try check((try statusText("production", in: recoveryPanel)).contains("Use shared access"), "source recovery explains the handoff inline")
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
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)
        backButton.imagePosition = .imageLeading; backButton.contentTintColor = .controlAccentColor
        backButton.setAccessibilityLabel("Back to AWS profiles")
        pageTitle.font = .systemFont(ofSize: 13, weight: .semibold); pageTitle.identifier = .init("aws-accounts-page-title")
        pageHeader.orientation = .horizontal; pageHeader.alignment = .centerY; pageHeader.spacing = 8
        for item in [backButton, pageTitle, NSView()] { pageHeader.addArrangedSubview(item) }
        pageHeader.isHidden = true
        let done = NSButton(title: "Done", target: self, action: #selector(closePanel)); done.keyEquivalent = "\u{1b}"
        cancel.target = self; cancel.action = #selector(cancelSignIn); cancel.isHidden = true
        let footerViews: [NSView] = embedded ? [sharingButton, NSView(), cancel, helpButton] : [helpButton, NSView(), cancel, done]
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
        let contentViews: [NSView] = embedded ? [pageHeader, subtitle, localAuthSection, scroll, status, footer] : [title, subtitle, tabs, scroll, status, footer]
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
            status.stringValue = error; render(); return
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
        updateSubtitle(); render()
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
            let sharing = tabs.selectedSegment == 1
            subtitle.stringValue = sharing ? "Choose paired Macs for AWS sharing. Approval is required on both Macs."
                : "AWS profiles are available across tabs on " + workstationName + "."
            pageTitle.stringValue = sharing ? "AWS Sharing" : ""
            pageHeader.isHidden = !sharing; backButton.isHidden = !sharing
            sharingButton.isHidden = !isLocalWorkstation || sharing
            helpButton.isHidden = false
        } else {
            subtitle.stringValue = tabs.selectedSegment == 0
                ? "Manage profiles for commands on This Mac. Existing profiles are detected automatically."
                : "Choose which paired Macs may exchange selected AWS access. Approval is required on both Macs."
        }
    }

    @objc private func openSharing() {
        guard isLocalWorkstation else { return }
        tabs.selectedSegment = 1
        if embedded && !agent.connected { agent.connect { [weak self] _ in self?.refresh() } }
        changeTab()
    }

    @objc private func backToProfiles() {
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
                self.peerState = result as? [String: Any] ?? [:]; self.render()
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
                    "ssoSessions": catalog["ssoSessions"] ?? [], "error": actionError ?? "",
                    "awsPeers": peerState["awsPeers"] ?? []]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return }
        let minute = Int(now.timeIntervalSince1970 / 60)
        let signature = "\(syncing):\(pending):\(minute):\(isLocalWorkstation):\(snapshotStale):\(remoteCanManage):\(remoteControlActive):\(allowedRemoteOperations.sorted()):" + String(decoding: data, as: UTF8.self)
        guard signature != rowsSignature else { return }
        let position = scroll.contentView.bounds.origin
        rowsSignature = signature; clearRows()
        if syncing { renderMacs() } else { renderProfiles() }
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

    private var signInBusy: Bool { !(catalog["signInProfile"] as? String ?? "").isEmpty }

    // Buttons only. Status words such as Ready or Check failed live in the
    // status line so the right column always means "something to click".
    private func profileButton(_ action: AWSProfileRowAction, item: AWSProfilePresentation) -> NSButton? {
        let remoteOperation: String?
        switch action {
        case .shareAccess: remoteOperation = "aws.source.enable"
        case .useSharedAccess: remoteOperation = "aws.use"
        case .refreshAccess: remoteOperation = "aws.refresh"
        case .signIn, .signInAgain, .syncNow, .review: remoteOperation = nil
        default: return nil
        }
        if !isLocalWorkstation {
            if action == .signIn || action == .signInAgain {
                guard item.sourceCheck.state == "signInRequired", localSignInHandler != nil else { return nil }
                let value = NSButton(title: "Sign In Here…", target: self, action: #selector(invokeAction(_:)))
                buttonActions[ObjectIdentifier(value)] = { [weak self] in self?.requestLocalSignIn(item.id) }
                value.isEnabled = !pending && !snapshotStale
                value.toolTip = "Sign in on This Mac, then share access with " + workstationName + " through your approved connection."
                value.setAccessibilityLabel("Sign in on This Mac for " + item.name)
                return value
            }
            if action == .review { return button("Review…") { [weak self] in self?.showReview(item) } }
            guard let remoteOperation, allows(remoteOperation) else { return nil }
        }
        let title: String
        if action == .useSharedAccess {
            title = recoversNativeSource(item) ? "Use Shared Access…" : scoped(action.title) + (canInstallImmediately(item) ? "" : "…")
        } else { title = action.title }
        let value = button(title) { [weak self] in self?.performProfileAction(action, item: item) }
        value.setAccessibilityLabel(title + " for " + item.name)
        if action == .signIn || action == .signInAgain { value.isEnabled = value.isEnabled && !signInBusy }
        return value
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
        case .review: showReview(item)
        case .ready, .signingIn, .refreshing, .accessDenied, .checkFailed, .networkUnavailable: break
        }
    }

    private func showReview(_ item: AWSProfilePresentation) {
        let title = item.name + " needs review"
        let text = "Different sign-ins provide conflicting identities for this profile. Choose the intended account on the Mac that shares it, then sync again."
        if let alertForTesting { alertForTesting(title, text); return }
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = text
        alert.addButton(withTitle: "OK"); if let ownerWindow { alert.beginSheetModal(for: ownerWindow) }
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

    /// The best known time this profile's issued credentials stop working.
    private func accessEnd(_ item: AWSProfilePresentation, source: Bool) -> Double? {
        let values = [source && !item.isInstalled ? item.verifiedNativeExpiration(now: now) : nil, item.usableExpiration(now: now),
                      item.sourceCheck.expiration.flatMap { $0 > now.timeIntervalSince1970 ? $0 : nil }]
        return values.compactMap { $0 }.max()
    }

    // One status line per profile. A grouped profile never repeats the
    // session's sign-in prompt; it says what that means for this profile.
    private func profileStatus(_ item: AWSProfilePresentation, presentation: AWSProfileRowState, source: Bool,
                               session: AWSSessionPresentation?) -> (String, Bool) {
        if let session {
            let ended = session.state == "signedOut" || (session.state == "signedIn" && (session.expectedEnd.map { $0 <= now.timeIntervalSince1970 } ?? false))
            if ended, presentation.primaryAction != .useSharedAccess || recoversNativeSource(item) {
                if let end = accessEnd(item, source: source) { return ("Access until " + AWSSessionPresentation.moment(end, now: now), true) }
                if item.hasLocalProfile || source { return ("Expired · sign in above to renew", true) }
            }
        }
        var text = presentation.availabilityText
        switch presentation.primaryAction {
        case .signingIn: text = "Signing in…"
        case .refreshing: text = "Checking access…"
        case .ready: text = text.isEmpty ? "Ready" : "Ready · " + text
        case .accessDenied: text = "Access denied · AWS refused this account or role"
        case .checkFailed: text = "Couldn’t check access · choose Check Access in the menu"
        case .networkUnavailable: text = "Can’t reach AWS · waiting for internet"
        default: break
        }
        if session != nil {
            if text.contains("Sign in") || text == "Sign-in needed" { text = "Renewal paused · sign in above" }
            if text == "Not checked" { text = source ? "Not checked yet" : "Not shared" }
        }
        if session == nil && text == "Not checked" { text = "Not shared" }
        return (text, presentation.needsAttention)
    }

    private func moreButton(_ menu: NSMenu, label: String) -> NSButton {
        let more = NSButton(image: NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Actions") ?? NSImage(), target: self, action: #selector(showActions(_:)))
        more.isBordered = false; more.menu = menu; more.isEnabled = !pending && menu.items.contains { $0.isEnabled }
        more.isHidden = menu.items.isEmpty; more.setAccessibilityLabel(label); more.toolTip = label
        return more
    }

    private func sessionHeader(_ session: AWSSessionPresentation, members: [AWSProfilePresentation]) -> NSView {
        let summary = session.summary(profileCount: members.count, now: now)
        let row = NSView(); row.identifier = .init("aws-session-row"); row.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: session.title.uppercased())
        title.font = .systemFont(ofSize: 11, weight: .semibold); title.textColor = .secondaryLabelColor
        title.identifier = .init("aws-session-name"); title.toolTip = session.portal
        let state = NSTextField(labelWithString: summary.status)
        state.font = .systemFont(ofSize: 14, weight: .semibold)
        state.textColor = summary.needsAttention ? .systemOrange : .labelColor
        state.identifier = .init("aws-session-state")
        let detail = NSTextField(labelWithString: summary.detail)
        detail.font = .systemFont(ofSize: 12); detail.textColor = .secondaryLabelColor
        detail.identifier = .init("aws-session-detail")
        for field in [title, state, detail] {
            field.lineBreakMode = .byTruncatingTail; field.maximumNumberOfLines = 1; field.toolTip = field.toolTip ?? field.stringValue
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let menu = NSMenu(); menu.autoenablesItems = false; menu.delegate = self
        if isLocalWorkstation {
            let lengthItem = NSMenuItem(title: "Session Length", action: nil, keyEquivalent: "")
            let lengths = NSMenu(); lengths.autoenablesItems = false; lengths.delegate = self
            let automatic = session.durationSource == "custom" ? "Automatic (AWS default 8 hours)" : "Automatic (" + session.lengthDescription + ")"
            addMenuItem(automatic, to: lengths) { [weak self] in self?.configureSession(session.id, duration: nil) }
            lengths.items.last?.state = session.durationSource == "custom" ? .off : .on
            lengths.addItem(.separator())
            for choice in AWSSessionPresentation.lengthChoices {
                addMenuItem(AWSSessionPresentation.length(choice), to: lengths) { [weak self] in self?.configureSession(session.id, duration: choice) }
                lengths.items.last?.state = session.durationSource == "custom" && abs(session.duration - choice) < 1 ? .on : .off
            }
            lengthItem.submenu = lengths; menu.addItem(lengthItem)
            let help = NSMenuItem(title: "Match the session length your AWS administrator set.", action: nil, keyEquivalent: "")
            help.isEnabled = false; menu.addItem(help)
            if summary.action == .extend || summary.action == .signInAgain {
                menu.addItem(.separator())
                addMenuItem("Sign In Without Ending Session", to: menu, enabled: !signInBusy) { [weak self] in
                    guard let first = members.first else { return }; self?.request("aws.signIn.start", ["profileId": first.id])
                }
            }
        }
        let more = moreButton(menu, label: "Actions for " + session.title)
        more.identifier = .init("aws-session-actions")
        var actionView: NSView = NSView()
        if let action = summary.action, let first = members.first {
            switch action {
            case .cancel:
                if isLocalWorkstation {
                    let value = button("Cancel") { [weak self] in self?.cancelSignIn() }
                    value.identifier = .init("aws-session-primary"); actionView = value
                }
            case .signIn, .extend, .signInAgain:
                if isLocalWorkstation {
                    let value = button(action.title) { [weak self] in
                        guard let self else { return }
                        if action == .signIn { self.request("aws.signIn.start", ["profileId": first.id]) }
                        else { self.confirmRestart(session, profileID: first.id, count: members.count, restart: action == .extend) }
                    }
                    value.isEnabled = value.isEnabled && !signInBusy
                    value.bezelColor = action == .signIn ? .controlAccentColor : nil
                    value.setAccessibilityLabel(action.title + " " + session.title)
                    value.identifier = .init("aws-session-primary"); actionView = value
                } else if action == .signIn, localSignInHandler != nil,
                          let target = members.first(where: { $0.sourceCheck.state == "signInRequired" }) ?? members.first {
                    let value = NSButton(title: "Sign In Here…", target: self, action: #selector(invokeAction(_:)))
                    buttonActions[ObjectIdentifier(value)] = { [weak self] in self?.requestLocalSignIn(target.id) }
                    value.isEnabled = !pending && !snapshotStale
                    value.toolTip = "Sign in on This Mac, then share access with " + workstationName + " through your approved connection."
                    value.identifier = .init("aws-session-primary"); actionView = value
                }
            }
        }
        let divider = NSBox(); divider.boxType = .separator
        for child in [title, state, detail, actionView, more, divider] { child.translatesAutoresizingMaskIntoConstraints = false; row.addSubview(child) }
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 84),
            more.trailingAnchor.constraint(equalTo: row.trailingAnchor), more.widthAnchor.constraint(equalToConstant: 28),
            more.heightAnchor.constraint(equalToConstant: 28), more.centerYAnchor.constraint(equalTo: state.centerYAnchor),
            actionView.trailingAnchor.constraint(equalTo: more.leadingAnchor, constant: -6), actionView.widthAnchor.constraint(equalToConstant: profileActionWidth),
            actionView.heightAnchor.constraint(equalToConstant: 28), actionView.centerYAnchor.constraint(equalTo: state.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: row.leadingAnchor), title.trailingAnchor.constraint(equalTo: actionView.leadingAnchor, constant: -12),
            title.topAnchor.constraint(equalTo: row.topAnchor, constant: 14), title.heightAnchor.constraint(equalToConstant: 14),
            state.leadingAnchor.constraint(equalTo: row.leadingAnchor), state.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            state.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4), state.heightAnchor.constraint(equalToConstant: 18),
            detail.leadingAnchor.constraint(equalTo: row.leadingAnchor), detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            detail.topAnchor.constraint(equalTo: state.bottomAnchor, constant: 3), detail.heightAnchor.constraint(equalToConstant: 16),
            divider.leadingAnchor.constraint(equalTo: row.leadingAnchor), divider.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: row.bottomAnchor), divider.heightAnchor.constraint(equalToConstant: 1)
        ])
        return row
    }

    private func groupHeading(_ text: String) -> NSView {
        let row = NSView(); row.identifier = .init("aws-group-heading"); row.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: text.uppercased())
        title.font = .systemFont(ofSize: 11, weight: .semibold); title.textColor = .secondaryLabelColor
        title.translatesAutoresizingMaskIntoConstraints = false; row.addSubview(title)
        NSLayoutConstraint.activate([row.heightAnchor.constraint(equalToConstant: 34),
            title.leadingAnchor.constraint(equalTo: row.leadingAnchor), title.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            title.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -6)])
        return row
    }

    private var profileActionWidth: CGFloat { embedded ? (profileRows.contains(where: recoversNativeSource) ? 144 : 124) : 140 }

    private func addListRow(_ row: NSView) {
        list.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor, constant: -12).isActive = true
    }

    private func renderProfiles() {
        profileRows = AWSProfilePresentation.rows(catalog: catalog)
        sessionRows = AWSSessionPresentation.sessions(catalog: catalog)
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
        // A receiver runs on access from another Mac, so it is never grouped
        // under this Mac's browser sign-in even when it shares an SSO session.
        func sessionFor(_ item: AWSProfilePresentation) -> AWSSessionPresentation? {
            guard !(item.isInstalled && !sources.contains(item.id)) else { return nil }
            return sessionRows.first { $0.profileIDs.contains(item.id) }
        }
        var grouped: [(AWSSessionPresentation?, [AWSProfilePresentation])] = sessionRows.map { session in
            (session, profileRows.filter { sessionFor($0)?.id == session.id })
        }.filter { !$0.1.isEmpty }
        let others = profileRows.filter { sessionFor($0) == nil }
        if !others.isEmpty { grouped.append((nil, others)) }
        for (session, members) in grouped {
            if let session { addListRow(sessionHeader(session, members: members)) }
            else if grouped.count > 1 { addListRow(groupHeading(isLocalWorkstation ? "Other profiles" : "Other profiles on " + workstationName)) }
            for item in members {
                addListRow(profileRow(item, session: session, source: sources.contains(item.id), sourceStatus: states[item.id], signingIn: signingIn.contains(item.id)))
            }
        }
        let caption: String
        if !isLocalWorkstation {
            caption = remoteRequiresControl ? "Take Control to manage profiles on " + workstationName + ". Sign-in opens on This Mac."
                : "Profiles run on " + workstationName + ". Browser sign-in opens on This Mac."
        } else if !sessionRows.isEmpty {
            caption = "AWS does not report when a session ends. TerminalDB times it from your last sign-in."
        } else {
            caption = "Managed access renews automatically when connected."
        }
        addRow(NSStackView(views: [label(caption)]))
    }

    private func profileRow(_ item: AWSProfilePresentation, session: AWSSessionPresentation?, source: Bool, sourceStatus: String?, signingIn: Bool) -> NSView {
        let id = item.id
        let presentation = item.rowState(isSource: source, sourceStatus: sourceStatus, isSigningIn: signingIn, now: now)
        let (statusText, attention) = profileStatus(item, presentation: presentation, source: source, session: session)
        let title = NSTextField(labelWithString: item.name)
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.identifier = .init("aws-profile-name"); title.setAccessibilityIdentifier("aws-profile-name")
        let context = scoped(presentation.authenticationText)
        let identity = NSTextField(labelWithString: [item.identitySummary, context].filter { !$0.isEmpty }.joined(separator: " · "))
        identity.identifier = .init("aws-profile-identity")
        let state = NSTextField(labelWithString: statusText)
        state.identifier = .init("aws-profile-state"); state.setAccessibilityIdentifier("aws-profile-state")
        for field in [title, identity, state] {
            field.lineBreakMode = .byTruncatingTail; field.maximumNumberOfLines = 1
            field.toolTip = field.stringValue
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        identity.lineBreakMode = .byTruncatingMiddle
        identity.font = .systemFont(ofSize: 12); identity.textColor = .secondaryLabelColor
        state.font = .systemFont(ofSize: 12, weight: presentation.primaryAction == .ready && !attention ? .medium : .regular)
        state.textColor = attention ? .systemOrange : (presentation.primaryAction == .ready ? .labelColor : .secondaryLabelColor)
        identity.toolTip = presentation.authenticationTooltip
        if presentation.primaryAction == .accessDenied || presentation.primaryAction == .checkFailed || presentation.primaryAction == .networkUnavailable {
            state.toolTip = item.sourceCheck.guidance
        }
        // Grouped profiles get sign-in from their session header.
        var candidates = [presentation.primaryAction, presentation.secondaryAction].compactMap { $0 }
        if session != nil { candidates.removeAll { $0 == .signIn || $0 == .signInAgain } }
        let primary = candidates.lazy.compactMap { self.profileButton($0, item: item) }.first
        primary?.identifier = .init("aws-profile-primary")
        let menu = NSMenu(); menu.autoenablesItems = false; menu.delegate = self
        let checkOperation = source ? "aws.refresh" : "aws.check"
        addMenuItem(item.sourceCheck.state == "checking" ? "Checking Access…" : "Check Access", to: menu,
                    enabled: allows(checkOperation) && item.sourceCheck.state != "checking") { [weak self] in self?.checkAccess(id) }
        if let last = item.sourceCheck.checkedAt, last.isFinite {
            let note = NSMenuItem(title: "Last checked " + AWSSessionPresentation.moment(last, now: now), action: nil, keyEquivalent: "")
            note.isEnabled = false; menu.addItem(note)
        }
        menu.addItem(.separator())
        if allows("aws.source.enable") && !source && item.hasLocalProfile && !candidates.contains(.shareAccess) {
            addMenuItem(scoped("Share This Mac’s Access"), to: menu) { [weak self] in self?.request("aws.source.enable", ["profileId": id]) }
        }
        let receiver = item.isInstalled && !source
        if isLocalWorkstation && receiver && item.usableExpiration(now: now) == nil {
            addMenuItem("Sign In Here…", to: menu, enabled: !signInBusy) { [weak self] in self?.request("aws.signIn.start", ["profileId": id]) }
        } else if isLocalWorkstation && session == nil && (item.hasLocalProfile || source) && !candidates.contains(.signIn) && item.descriptor.kind == "sso" {
            addMenuItem("Sign In Here…", to: menu, enabled: !signInBusy) { [weak self] in self?.request("aws.signIn.start", ["profileId": id]) }
        }
        if !isLocalWorkstation, localSignInHandler != nil, receiver && item.usableExpiration(now: now) == nil, !recoversNativeSource(item) {
            addMenuItem("Sign In on This Mac…", to: menu) { [weak self] in self?.requestLocalSignIn(id) }
            menu.items.last?.isEnabled = !pending && !snapshotStale
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
        addMenuItem("Copy Profile Name", to: menu, enabled: true) {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.name, forType: .string)
        }
        menu.items.last?.isEnabled = true
        menu.items.last?.toolTip = "Use with --profile or AWS_PROFILE in AWS commands."
        if allows("aws.remove") && (source || item.isInstalled) {
            menu.addItem(.separator())
            addMenuItem(scoped("Remove from This Mac…"), to: menu) { [weak self] in self?.remove(id: id, name: item.name) }
        }
        let more = moreButton(menu, label: "Actions for " + item.name)
        more.identifier = .init("aws-profile-actions"); more.isEnabled = !pending
        let row = NSView(); row.identifier = .init("aws-profile-row"); row.translatesAutoresizingMaskIntoConstraints = false
        let divider = NSBox(); divider.boxType = .separator
        let actionView: NSView = primary ?? NSView()
        let indent: CGFloat = session == nil ? 0 : 12
        for child in [title, identity, state, actionView, more, divider] { child.translatesAutoresizingMaskIntoConstraints = false; row.addSubview(child) }
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 74),
            more.trailingAnchor.constraint(equalTo: row.trailingAnchor), more.widthAnchor.constraint(equalToConstant: 28),
            more.heightAnchor.constraint(equalToConstant: 28), more.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            actionView.trailingAnchor.constraint(equalTo: more.leadingAnchor, constant: -6), actionView.widthAnchor.constraint(equalToConstant: profileActionWidth),
            actionView.heightAnchor.constraint(equalToConstant: 28), actionView.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: indent), title.trailingAnchor.constraint(equalTo: actionView.leadingAnchor, constant: -12),
            title.topAnchor.constraint(equalTo: row.topAnchor, constant: 10), title.heightAnchor.constraint(equalToConstant: 18),
            identity.leadingAnchor.constraint(equalTo: title.leadingAnchor), identity.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            identity.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3), identity.heightAnchor.constraint(equalToConstant: 16),
            state.leadingAnchor.constraint(equalTo: title.leadingAnchor), state.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            state.topAnchor.constraint(equalTo: identity.bottomAnchor, constant: 3), state.heightAnchor.constraint(equalToConstant: 16),
            divider.leadingAnchor.constraint(equalTo: title.leadingAnchor), divider.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: row.bottomAnchor), divider.heightAnchor.constraint(equalToConstant: 1)
        ])
        return row
    }

    private func confirmRestart(_ session: AWSSessionPresentation, profileID: String, count: Int, restart: Bool) {
        if let confirmRestartForTesting { confirmRestartForTesting(session.id, restart); return }
        let alert = NSAlert()
        let profiles = count == 1 ? "the profile" : "all \(count) profiles"
        if restart {
            alert.messageText = "Extend " + session.title + "?"
            alert.informativeText = "AWS keeps an active session's original end time when you sign in again. To extend it, TerminalDB ends this session and opens your browser for a full sign-in.\n\nThe new session lasts about " + AWSSessionPresentation.length(session.duration) + " and renews " + profiles + " that use it. Access already issued keeps working until it expires."
            alert.addButton(withTitle: "End Session and Sign In")
        } else {
            alert.messageText = "Sign in to " + session.title + " again?"
            alert.informativeText = "AWS may keep the current session's end time. Access already issued keeps working until it expires."
            alert.addButton(withTitle: "Sign In")
        }
        alert.addButton(withTitle: "Cancel")
        guard let ownerWindow else { return }
        alert.beginSheetModal(for: ownerWindow) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.request("aws.signIn.start", restart ? ["profileId": profileID, "restart": true] : ["profileId": profileID])
        }
    }

    private func configureSession(_ id: String, duration: Double?) {
        var payload: [String: Any] = ["sessionId": id]
        if let duration { payload["duration"] = duration }
        request("aws.session.configure", payload)
    }

    private func addMenuItem(_ title: String, to menu: NSMenu, enabled: Bool = true, action: @escaping () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(invokeMenuAction(_:)), keyEquivalent: "")
        let id = UUID().uuidString; item.representedObject = id; item.target = self; actions[id] = action
        item.isEnabled = enabled && !pending && canMutate
        menu.addItem(item)
    }
    @objc private func showActions(_ sender: NSButton) { sender.menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender) }
    public func menuWillOpen(_ menu: NSMenu) { trackingMenu = true }
    public func menuDidClose(_ menu: NSMenu) { trackingMenu = false; DispatchQueue.main.async { [weak self] in self?.render() } }
    @objc private func invokeMenuAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }; actions[id]?()
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
            actionError = "Shared access changed. Check this profile again before switching it."; status.stringValue = actionError ?? ""; return
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
        guard !pending else { return }; pending = true; rowsSignature = ""; actionError = nil; render()
        if operation == "aws.signIn.start" {
            status.stringValue = payload["restart"] as? Bool == true ? "Ending the current AWS session, then opening your browser…" : "Starting AWS sign-in in your browser on This Mac…"
        } else { status.stringValue = operation == "aws.session.configure" ? "Saving session length…" : "Updating AWS access…" }
        let generation = lifecycle
        host.request(operation, payload: payload as NSDictionary) { [weak self] result in
            guard let self, self.lifecycle == generation, self.clientMatchesWorkstation else { return }; self.pending = false; self.rowsSignature = ""
            self.applyActionResult(operation, result: result)
            self.render()
            if self.isLocalWorkstation && self.agent.connected && !["aws.check", "aws.refresh", "aws.session.configure", "aws.signIn.start"].contains(operation) { self.agent.request("aws.sync.now", payload: [:]) { _ in } }
            self.refresh()
        }
    }
    private func applyActionResult(_ operation: String, result: NSDictionary) {
        let checking = operation == "aws.check" || operation == "aws.refresh"
        actionError = result["error"] as? String
        if actionError == nil && checking && result["accepted"] as? Bool == false { actionError = "Access checks are busy. Try Check Access again in a moment." }
        let done: String
        switch operation {
        case _ where checking: done = ""
        case "aws.signIn.start": done = "Complete AWS sign-in in your browser."
        case "aws.session.configure": done = "Session length saved."
        default: done = "Saved. Approved Macs sync automatically over your LAN or VPN."
        }
        status.stringValue = actionError ?? done
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
    public func windowShouldClose(_ sender: NSWindow) -> Bool { prepareClose() }
    @objc private func closePanel() { if prepareClose() { panel.close() } }
    public func windowWillClose(_ notification: Notification) {
        stop(); Self.current = nil
    }
}
