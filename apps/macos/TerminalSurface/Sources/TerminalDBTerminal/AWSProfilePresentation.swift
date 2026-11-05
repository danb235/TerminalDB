import Foundation

// A profile name is a local alias. The validated descriptor identity, rather
// than its display name or the latest publishing Mac, determines each row.
struct AWSProfileAuthentication {
    let state: String
    let sessionName: String?
    let expiration: Double?

    init(_ value: [String: Any]?) {
        let candidate = value?["state"] as? String ?? "unknown"
        state = ["current", "expired", "missing", "unknown", "notApplicable"].contains(candidate) ? candidate : "unknown"
        sessionName = (value?["sessionName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        expiration = value?["expiresAt"] as? Double
    }
    var needsRenewal: Bool { state != "current" && state != "notApplicable" }
    var summary: String {
        switch state {
        case "current": return "SSO signed in"
        case "expired": return "SSO needs renewal"
        case "missing": return "SSO sign-in needed"
        default: return "SSO status unavailable"
        }
    }
    var label: String { summary + (sessionName.map { " · " + $0 } ?? "") }
}

struct AWSSourceCheck {
    let state: String
    let checkedAt: Double?
    let expiration: Double?
    let needsSharedRenewal: Bool
    init(_ value: [String: Any]? = nil) {
        let candidate = value?["state"] as? String ?? "notChecked"
        state = ["ready", "checking", "signInRequired", "networkUnavailable", "accessDenied", "checkFailed"].contains(candidate) ? candidate : "notChecked"
        checkedAt = value?["checkedAt"] as? Double
        expiration = value?["expiresAt"] as? Double
        needsSharedRenewal = value?["needsSharedRenewal"] as? Bool == true
    }
    var guidance: String {
        switch state {
        case "ready": return "Access is ready."
        case "checking": return "Checking access…"
        case "signInRequired": return "AWS requires a new sign-in to renew access."
        case "networkUnavailable": return "AWS could not be reached. Check this Mac’s internet connection."
        case "accessDenied": return "AWS denied access to this account or role. Check its permissions."
        case "checkFailed": return "Access could not be checked. Try Check Access again."
        default: return "Access has not been checked yet."
        }
    }
}

enum AWSProfileRowAction: Equatable {
    case signIn, signInAgain, shareAccess, useSharedAccess, syncNow, refreshAccess
    case review, ready, signingIn, refreshing, accessDenied, checkFailed, networkUnavailable

    var title: String {
        switch self {
        case .signIn: return "Sign In"
        case .signInAgain: return "Sign In Again"
        case .shareAccess: return "Share Access"
        case .useSharedAccess: return "Use on This Mac"
        case .syncNow: return "Sync Now"
        case .refreshAccess: return "Refresh Access"
        case .review: return "Review…"
        case .ready: return "Ready"
        case .signingIn: return "Signing In…"
        case .refreshing: return "Checking…"
        case .accessDenied: return "Access denied"
        case .checkFailed: return "Check failed"
        case .networkUnavailable: return "Can’t reach AWS"
        }
    }
}

struct AWSProfileRowState {
    var primaryAction: AWSProfileRowAction?
    var secondaryAction: AWSProfileRowAction?
    var authenticationText: String
    var authenticationTooltip: String
    var availabilityText: String
    var needsAttention: Bool
    var showsAuthentication: Bool
}

struct AWSProfilePresentation {
    var id: String
    var descriptor: AWSProfileDescriptor
    var localNames: [String]
    var installedNames: [String]
    var sharedNames: [String]
    var sourceNames: [String]
    var available: Bool
    var expiration: Double?
    var status: String
    var authentication: AWSProfileAuthentication
    var sourceCheck = AWSSourceCheck()
    var incomingAvailable = false
    var incomingSourceNames: [String] = []
    var incomingExpiration: Double? = nil

    var name: String { installedNames.first ?? localNames.first ?? descriptor.name }
    var hasLocalProfile: Bool { !localNames.isEmpty }
    var isInstalled: Bool { !installedNames.isEmpty }
    var identitySummary: String {
        if descriptor.kind == "sso" { return [descriptor.accountID, descriptor.roleName].filter { !$0.isEmpty }.joined(separator: " · ") }
        let principal = descriptor.loginSession.split(separator: ":", maxSplits: 5).last.map(String.init) ?? ""
        return [descriptor.accountID, principal].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    func usableExpiration(now: Date = Date()) -> Double? {
        let candidates = [available ? expiration : nil, !isInstalled && hasLocalProfile ? sourceCheck.expiration : nil].compactMap { $0 }
        return candidates.filter { $0.isFinite && $0 > now.timeIntervalSince1970 }.max()
    }

    // An unmapped native profile still uses the AWS CLI's own provider. A
    // usable received credential does not change that configuration by itself.
    func verifiedNativeExpiration(now: Date = Date()) -> Double? {
        guard hasLocalProfile, !isInstalled,
              ["ready", "checking", "networkUnavailable", "signInRequired"].contains(sourceCheck.state),
              let expiry = sourceCheck.expiration, expiry.isFinite, expiry > now.timeIntervalSince1970 else { return nil }
        return expiry
    }

    func needsIncomingSourceRecovery(isSource: Bool, now: Date = Date()) -> Bool {
        guard isSource, !isInstalled, incomingAvailable, available, status != "Choose Account Again",
              let expiry = incomingExpiration, expiry.isFinite, expiry > now.timeIntervalSince1970 else { return false }
        return sourceCheck.state == "signInRequired" || verifiedNativeExpiration(now: now) == nil
    }

    // Only a provider-confirmed authentication failure requires another login.
    // OAuth token-cache timestamps do not establish whether renewal can work.
    func rowState(isSource: Bool, sourceStatus: String?, isSigningIn: Bool,
                  now: Date = Date()) -> AWSProfileRowState {
        let nativeSource = isSource && hasLocalProfile && !isInstalled
        let usable = nativeSource ? verifiedNativeExpiration(now: now) != nil : usableExpiration(now: now) != nil
        let receiver = isInstalled && !isSource
        let shared = !isSource && (!hasLocalProfile || receiver || available)
        let providers = sourceNames.joined(separator: ", ")
        let context = isSource ? "Shared from This Mac" : shared ? (providers.isEmpty ? "Shared access" : "From " + providers) : "On This Mac"
        var state = AWSProfileRowState(primaryAction: nil, secondaryAction: nil,
            authenticationText: context, authenticationTooltip: shared
                ? "Shared AWS access runs on this Mac. Its providing Mac renews it when connected."
                : isSource ? "This Mac renews and shares the profiles you select." : "This profile is configured on this Mac. Sharing is optional.",
            availabilityText: "Not checked", needsAttention: false, showsAuthentication: true)
        if status == "Choose Account Again" {
            state.primaryAction = .review; state.availabilityText = "Choose the shared account to use"; state.needsAttention = true
            return state
        }
        if isSigningIn { state.primaryAction = .signingIn; state.availabilityText = ""; return state }
        if needsIncomingSourceRecovery(isSource: isSource, now: now) {
            state.primaryAction = .useSharedAccess; state.secondaryAction = nil
            state.authenticationText = incomingSourceNames.isEmpty ? "From an approved Mac" : "From " + incomingSourceNames.joined(separator: ", ")
            state.authenticationTooltip = "Received access is available. Confirm Use Shared Access to switch this profile from its native sign-in to the approved copy."
            state.availabilityText = "Use shared access to continue"; state.needsAttention = true
            return state
        }
        if shared && sourceCheck.needsSharedRenewal && !usable {
            state.primaryAction = .syncNow; state.availabilityText = "Waiting for shared access"; state.needsAttention = true
            return state
        }
        let incomingRecovery = !isSource && !isInstalled && hasLocalProfile && available &&
            (expiration.map { $0.isFinite && $0 > now.timeIntervalSince1970 } ?? false)
        if !incomingRecovery && !sourceCheck.needsSharedRenewal && (sourceCheck.state == "accessDenied" || sourceCheck.state == "checkFailed") {
            state.primaryAction = sourceCheck.state == "accessDenied" ? .accessDenied : .checkFailed
            state.availabilityText = sourceCheck.state == "accessDenied" ? "Review this role’s permissions in Details" : "Open Details to check access again"
            state.needsAttention = true
            return state
        }

        if usable {
            if !isInstalled && (shared || !hasLocalProfile) {
                state.primaryAction = .useSharedAccess
                state.availabilityText = "Ready to use"
            } else if !isSource && !receiver {
                state.primaryAction = .shareAccess
                state.availabilityText = "Ready · Not shared"
            } else {
                state.primaryAction = .ready
                state.availabilityText = isSource ? "Renews automatically" : "Updates automatically when connected"
            }
            if shared && !receiver && hasLocalProfile { state.secondaryAction = .shareAccess }
            if !shared || isSource {
                switch sourceCheck.state {
                case "signInRequired": state.secondaryAction = .signIn; state.availabilityText = "Sign in to keep renewal working"; state.needsAttention = true
                case "networkUnavailable": state.availabilityText = "Waiting for internet to renew"; state.needsAttention = true
                case "accessDenied": state.availabilityText = "AWS denied renewal · Details"; state.needsAttention = true
                case "checkFailed": state.availabilityText = "Renewal needs attention · Details"; state.needsAttention = true
                default: break
                }
            } else if sourceCheck.state == "networkUnavailable" {
                state.availabilityText = "Last check couldn’t reach AWS"; state.needsAttention = true
            }
            return state
        }
        if shared {
            state.primaryAction = .syncNow
            state.availabilityText = "Waiting for shared access"
            state.needsAttention = true
            return state
        }
        switch sourceCheck.state {
        case "signInRequired":
            state.primaryAction = .signIn; state.secondaryAction = !isSource && hasLocalProfile ? .shareAccess : nil
            state.availabilityText = "Sign-in needed"; state.needsAttention = true
        case "checking":
            state.primaryAction = isSource ? .refreshing : .shareAccess
            state.availabilityText = isSource ? "" : "Checking access…"
        case "networkUnavailable": state.availabilityText = "Waiting for internet"; state.needsAttention = true
        case "accessDenied": state.availabilityText = "AWS access denied · Details"; state.needsAttention = true
        case "checkFailed": state.availabilityText = "Couldn’t check access · Details"; state.needsAttention = true
        default: break
        }
        if sourceCheck.state == "networkUnavailable" { state.primaryAction = .networkUnavailable }
        if !isSource && state.primaryAction == nil { state.primaryAction = .shareAccess }
        return state
    }

    static func rows(catalog: [String: Any]) -> [Self] {
        let profiles = decode(catalog["profiles"])
        let configured = (catalog["configuredProfileIDs"] as? [String]).map(Set.init)
        let locals = profiles.filter { configured?.contains($0.id) ?? true }
        let shared = catalog["accounts"] as? [[String: Any]] ?? []
        let installed = catalog["installed"] as? [[String: Any]] ?? []
        let authentication = catalog["authentication"] as? [String: [String: Any]] ?? [:]
        let checks = catalog["sourceChecks"] as? [String: [String: Any]] ?? [:]
        var candidates: [String: [AWSProfileDescriptor]] = [:]
        for local in locals { candidates[local.id, default: []].append(local) }
        for profile in profiles { candidates[profile.id, default: []].append(profile) }
        for value in shared + installed {
            if let descriptor = decodeOne(value["descriptor"]) { candidates[descriptor.id, default: []].append(descriptor) }
        }
        return candidates.compactMap { id, descriptors -> Self? in
            let local = locals.filter { $0.id == id }.sorted { before($0.name, $1.name) }
            let mappings = installed.filter { $0["profileId"] as? String == id }
            let account = shared.first { $0["profileId"] as? String == id }
            // Local metadata always wins over a remote alias; incoming renewal
            // or a change of providing Mac must not rename the local row.
            guard let descriptor = local.first ?? descriptors.sorted(by: { before($0.name, $1.name) }).first else { return nil }
            let names = unique((account?["profileNames"] as? [String] ?? []) + descriptors.map(\.name))
            return Self(id: id, descriptor: descriptor, localNames: unique(local.map(\.name)),
                        installedNames: unique(mappings.compactMap { $0["targetName"] as? String }),
                        sharedNames: names, sourceNames: unique(account?["sourceNames"] as? [String] ?? []),
                        available: account?["available"] as? Bool == true,
                        expiration: account?["expires"] as? Double,
                        status: account?["status"] as? String ?? "Not shared",
                        authentication: AWSProfileAuthentication(authentication[id]), sourceCheck: AWSSourceCheck(checks[id]),
                        incomingAvailable: account?["incomingAvailable"] as? Bool == true,
                        incomingSourceNames: unique(account?["incomingSourceNames"] as? [String] ?? []),
                        incomingExpiration: account?["incomingExpires"] as? Double)
        }.sorted { a, b in a.name == b.name ? before(a.identitySummary, b.identitySummary) : before(a.name, b.name) }
    }

    // Prefer an existing matching local alias. A name occupied by a different
    // identity is never suggested for replacement, regardless of source Mac.
    func suggestedName(rows: [Self], occupiedNames: Set<String> = []) -> String {
        if let local = localNames.first { return local }
        if let installed = installedNames.first { return installed }
        let occupied = occupiedNames.union(rows.filter { $0.id != id }.flatMap { $0.localNames + $0.installedNames })
        if !occupied.contains(descriptor.name) { return descriptor.name }
        let suffix = descriptor.accountID.isEmpty ? "shared" : String(descriptor.accountID.suffix(4))
        var prefix = descriptor.name
        while prefix.utf8.count > 100 { prefix.removeLast() }
        let proposed = prefix + "-" + suffix
        if !occupied.contains(proposed) { return proposed }
        for number in 2...999 where !occupied.contains(proposed + "-\(number)") { return proposed + "-\(number)" }
        return prefix + "-" + String(id.prefix(12))
    }

    func suggestedAdditionalName(rows: [Self], occupiedNames: Set<String> = []) -> String {
        if let local = localNames.first(where: { !installedNames.contains($0) }) { return local }
        // Unlike first-time setup, all names of this identity are occupied too.
        // This avoids suggesting an already-managed name and silently doing
        // nothing when the user explicitly requested another local name.
        let occupied = occupiedNames.union(rows.flatMap { $0.localNames + $0.installedNames })
            .union(localNames).union(installedNames)
        var stem = name
        while stem.utf8.count > 116 { stem.removeLast() }
        if stem.isEmpty { stem = "aws-profile" }
        for number in 2...(occupied.count + 2) {
            let candidate = stem + "-\(number)"
            if !occupied.contains(candidate) { return candidate }
        }
        // The finite set of occupied names guarantees an available candidate.
        return stem + "-\(occupied.count + 3)"
    }

    static func namesConflict(_ name: String, rows: [Self]) -> Bool { Set(rows.filter { $0.name == name }.map(\.id)).count > 1 }
    private static func before(_ a: String, _ b: String) -> Bool { a.localizedStandardCompare(b) == .orderedAscending }
    private static func unique(_ names: [String]) -> [String] { Array(Set(names.filter { !$0.isEmpty })).sorted(by: before) }
    private static func decode(_ value: Any?) -> [AWSProfileDescriptor] { (value as? [[String: Any]] ?? []).compactMap { decodeOne($0) } }
    private static func decodeOne(_ value: Any?) -> AWSProfileDescriptor? {
        guard let value, JSONSerialization.isValidJSONObject(value), let bytes = try? JSONSerialization.data(withJSONObject: value),
              let descriptor = try? JSONDecoder().decode(AWSProfileDescriptor.self, from: bytes), (try? descriptor.validate()) != nil else { return nil }
        return descriptor
    }
}
