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

enum AWSProfileRowAction: Equatable {
    case signIn, signInAgain, shareAccess, useSharedAccess, syncNow, refreshAccess
    case review, ready, signingIn, refreshing

    var title: String {
        switch self {
        case .signIn: return "Sign In"
        case .signInAgain: return "Sign In Again"
        case .shareAccess: return "Share Access"
        case .useSharedAccess: return "Use on This Mac"
        case .syncNow: return "Sync Now"
        case .refreshAccess: return "Refresh Access"
        case .review: return "Review…"
        case .ready: return "Ready on This Mac"
        case .signingIn: return "Signing In…"
        case .refreshing: return "Refreshing…"
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

    var name: String { installedNames.first ?? localNames.first ?? descriptor.name }
    var hasLocalProfile: Bool { !localNames.isEmpty }
    var isInstalled: Bool { !installedNames.isEmpty }
    var identitySummary: String {
        if descriptor.kind == "sso" { return [descriptor.accountID, descriptor.roleName].filter { !$0.isEmpty }.joined(separator: " · ") }
        let principal = descriptor.loginSession.split(separator: ":", maxSplits: 5).last.map(String.init) ?? ""
        return [descriptor.accountID, principal].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // Receiving profiles use the shared credential provider, including aliases
    // whose original native sign-in is retained for restoration. That original
    // browser token does not determine whether the mapped profile works.
    func rowState(isSource: Bool, sourceStatus: String?, isSigningIn: Bool,
                  now: Date = Date()) -> AWSProfileRowState {
        let usable = available && (expiration.map { $0.isFinite && $0 > now.timeIntervalSince1970 } ?? false)
        let receiving = isInstalled && !isSource
        let sharedPresentation = receiving || (!isSource && (!hasLocalProfile || usable))
        let providers = sourceNames.joined(separator: ", ")
        let origin = providers.isEmpty ? "Shared access" : "From " + providers
        let time = expiration.flatMap { value -> String? in
            guard value.isFinite else { return nil }
            return DateFormatter.localizedString(from: Date(timeIntervalSince1970: value), dateStyle: .none, timeStyle: .short)
        }
        var tooltip = authentication.label
        if let value = authentication.expiration, value.isFinite {
            tooltip += "\nSSO sign-in expires: " + DateFormatter.localizedString(from: Date(timeIntervalSince1970: value), dateStyle: .short, timeStyle: .short)
        }
        var state = AWSProfileRowState(primaryAction: nil, secondaryAction: nil,
            authenticationText: authentication.summary, authenticationTooltip: tooltip,
            availabilityText: sourceStatus ?? (hasLocalProfile && !isSource ? "Not shared" : status),
            needsAttention: false, showsAuthentication: descriptor.kind == "sso" || sharedPresentation)

        if sharedPresentation {
            state.authenticationText = origin
            state.authenticationTooltip = providers.isEmpty
                ? "Shared AWS access can be used on this Mac without a local browser sign-in."
                : "Shared AWS access is provided by " + providers + ". Commands run on this Mac. A local browser sign-in is optional."
        }
        if status == "Choose Account Again" {
            state.primaryAction = .review
            state.availabilityText = "Choose the shared account to use"
            state.needsAttention = true
            return state
        }
        if isSigningIn {
            state.primaryAction = .signingIn
            if usable, let time { state.availabilityText = "Access until " + time }
            return state
        }
        if sharedPresentation {
            if usable {
                state.primaryAction = receiving ? .ready : .useSharedAccess
                state.secondaryAction = !receiving && hasLocalProfile ? .shareAccess : nil
                if let time { state.availabilityText = (receiving ? "Access until " : "Available until ") + time }
            } else {
                state.primaryAction = .syncNow
                state.secondaryAction = .signIn
                let expired = status == "Expired" || (expiration.map { $0.isFinite && $0 <= now.timeIntervalSince1970 } ?? false)
                state.availabilityText = expired ? "Shared access expired" : "Waiting for shared access"
                state.needsAttention = true
            }
            return state
        }

        let sourceNeedsSignIn = sourceStatus == "Sign in on this Mac to renew"
        let localSSONeedsSignIn = descriptor.kind == "sso" && authentication.state != "current"
        if usable, let time { state.availabilityText = "Access until " + time }
        if isSource {
            if sourceStatus == "Renewing…" {
                state.primaryAction = .refreshing
                state.availabilityText = "Updating access…"
            } else if !hasLocalProfile && !isInstalled && usable {
                // Signing in from received metadata can make this Mac a source
                // before any CLI alias exists. Keep the setup action visible.
                state.primaryAction = .useSharedAccess
                state.secondaryAction = localSSONeedsSignIn ? .signIn : .refreshAccess
                state.needsAttention = localSSONeedsSignIn
            } else if localSSONeedsSignIn || (descriptor.kind != "sso" && sourceNeedsSignIn) {
                state.primaryAction = .signIn
                state.secondaryAction = .refreshAccess
                state.needsAttention = true
            } else {
                state.primaryAction = .refreshAccess
                state.secondaryAction = .signInAgain
                if sourceNeedsSignIn || !usable {
                    state.availabilityText = sourceNeedsSignIn ? "Access needs renewal" : state.availabilityText
                    state.needsAttention = sourceNeedsSignIn
                }
            }
        } else if descriptor.kind != "sso" || authentication.state == "current" {
            state.primaryAction = .shareAccess
            state.secondaryAction = descriptor.kind == "sso" ? .signInAgain : .signIn
        } else {
            state.primaryAction = .signIn
            state.secondaryAction = .shareAccess
            state.needsAttention = true
        }
        return state
    }

    static func rows(catalog: [String: Any]) -> [Self] {
        let profiles = decode(catalog["profiles"])
        let configured = (catalog["configuredProfileIDs"] as? [String]).map(Set.init)
        let locals = profiles.filter { configured?.contains($0.id) ?? true }
        let shared = catalog["accounts"] as? [[String: Any]] ?? []
        let installed = catalog["installed"] as? [[String: Any]] ?? []
        let authentication = catalog["authentication"] as? [String: [String: Any]] ?? [:]
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
                        authentication: AWSProfileAuthentication(authentication[id]))
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
