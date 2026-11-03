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
