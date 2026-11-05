import Foundation

enum SharedAWSRemotePolicy {
    static let readOperations: Set<String> = ["aws.status", "aws.catalog"]
    static let remoteManagement: Set<String> = ["aws.check", "aws.refresh", "aws.use", "aws.source.enable", "aws.remove"]
    static let receiptOperations = remoteManagement.union(["aws.share", "aws.signIn.start", "aws.signIn.cancel"])

    static func controls(attached: Bool, lease: PeerControlLease?, principal: String, generation: UInt64?) -> Bool {
        guard attached, let generation else { return false }
        return lease?.allows(principal, generation: generation) == true
    }

    static func capabilities(local: Bool, controlling: Bool) -> [String: Any] {
        let allowed = local ? receiptOperations : (controlling ? remoteManagement : [])
        return ["allowedOperations": Array(allowed).sorted(), "canManage": local || controlling,
                "requiresControl": !local && !controlling, "canSignIn": local]
    }
}

// Status describes configured access on one execution workstation. It does not
// select AWS_PROFILE, inspect a shell's environment, or infer a login lifetime.
@objc(TDBAWSStatusModel)
public final class TDBAWSStatusModel: NSObject {
    @objc(summaryForCatalog:now:)
    public static func summary(for catalog: NSDictionary, now: Date) -> NSDictionary {
        summary(catalog as? [String: Any] ?? [:], now: now) as NSDictionary
    }

    @objc(fallbackSummaryForState:)
    public static func fallbackSummary(for state: String) -> NSDictionary {
        fallback(state: state) as NSDictionary
    }

    static func summary(_ catalog: [String: Any], now: Date) -> [String: Any] {
        guard now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 > 0,
              catalog["profiles"] is [[String: Any]], catalog["installed"] is [[String: Any]],
              catalog["accounts"] is [[String: Any]],
              catalog["configuredProfileIDs"] == nil || catalog["configuredProfileIDs"] is [String],
              catalog["sources"] == nil || catalog["sources"] is [String] else { return fallback(state: "unavailable") }
        let sources = Set(catalog["sources"] as? [String] ?? [])
        let candidates = AWSProfilePresentation.rows(catalog: catalog)
        guard candidates.allSatisfy({ (try? $0.descriptor.validate()) != nil }) else { return fallback(state: "unavailable") }
        let rows = candidates.filter { $0.hasLocalProfile || $0.isInstalled }
        var ready = 0, attention = 0, checking = 0, signInRequired = 0, denied = 0, network = 0
        for row in rows {
            let source = sources.contains(row.id)
            let state = row.rowState(isSource: source, sourceStatus: nil, isSigningIn: false, now: now)
            let check = row.sourceCheck
            let locallyVerified = row.verifiedNativeExpiration(now: now) != nil
            let sharedUsable = row.available && row.expiration.map { $0.isFinite && $0 > now.timeIntervalSince1970 } == true
            let usable = row.isInstalled ? sharedUsable : locallyVerified
            let blocked = check.state == "accessDenied" || (check.state == "checkFailed" && !check.needsSharedRenewal)
            if usable && !blocked && row.status != "Choose Account Again" { ready += 1 }
            // An unmapped received copy must not make an unchecked native
            // profile look usable. Only its own check can establish readiness.
            if state.needsAttention || blocked || (check.state == "signInRequired" && !(row.isInstalled && !source)) ||
                check.state == "networkUnavailable" || row.status == "Choose Account Again" ||
                (row.isInstalled && !sharedUsable) { attention += 1 }
            if check.state == "checking" { checking += 1 }
            if check.state == "signInRequired" && !(row.isInstalled && !source) { signInRequired += 1 }
            if check.state == "accessDenied" { denied += 1 }
            if check.state == "networkUnavailable" { network += 1 }
        }
        let title: String, detail: String, state: String
        if attention > 0 {
            title = signInRequired > 0 ? "AWS · Sign-in needed" : denied > 0 ? "AWS · Access denied"
                : network > 0 ? "AWS · Connection issue" : "AWS · Needs attention"
            detail = "\(ready) of \(rows.count) configured profiles ready. \(attention) need attention. Open AWS for details."
            state = "attention"
        } else if ready > 0 {
            title = "AWS · \(ready) ready"
            detail = "\(ready) of \(rows.count) configured profiles ready. Managed access renews automatically when connected."
            state = "ready"
        } else if rows.isEmpty {
            title = "AWS · Set up"; detail = "No AWS profiles are configured on this workstation."; state = "empty"
        } else {
            title = checking > 0 ? "AWS · Checking" : "AWS · Not checked"
            detail = checking > 0 ? "AWS access checks are in progress." : "Open AWS to check the profiles configured on this workstation."
            state = "unknown"
        }
        return ["title": title, "detail": detail, "state": state,
                "readyCount": ready, "attentionCount": attention, "configuredCount": rows.count]
    }

    static func fallback(state: String, counts: [String: Any] = [:]) -> [String: Any] {
        let title: String, detail: String
        switch state {
        case "loading": title = "AWS · Loading"; detail = "Loading this workstation’s AWS status."
        case "stale": title = "AWS · Updating"; detail = "AWS status is out of date. Cached details may have changed."
        case "disconnected": title = "AWS · Reconnecting"; detail = "Reconnect to this workstation to see its current AWS status."
        default: title = "AWS · Unavailable"; detail = "AWS status is unavailable. Open AWS for details."
        }
        return ["title": title, "detail": detail, "state": state,
                "readyCount": counts["readyCount"] as? Int ?? 0,
                "attentionCount": counts["attentionCount"] as? Int ?? 0,
                "configuredCount": counts["configuredCount"] as? Int ?? 0]
    }
}

// The serialized cache is immutable while locked, and is independent of the
// AWS/Keychain service queue. Reads only decode bounded metadata and apply time.
final class SharedAWSStatusCache {
    private let lock = NSLock()
    private var data: Data?
    private var updatedAt: Double?
    private var invalidated = false
    private var failed = false
    private var revision: UInt64 = 0
    private let maximumAge: Double = 90

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        invalidated = true; revision &+= 1
    }
    func ticket() -> UInt64 {
        lock.lock(); defer { lock.unlock() }; return revision
    }
    @discardableResult func replace(_ catalog: [String: Any], ticket: UInt64, now: Date = Date()) -> Bool {
        let safe = Self.metadata(catalog)
        guard JSONSerialization.isValidJSONObject(safe),
              let bytes = try? JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys]),
              bytes.count <= 2_097_152, now.timeIntervalSince1970.isFinite else {
            unavailable(ticket: ticket); return false
        }
        lock.lock(); defer { lock.unlock() }
        guard ticket == revision else { return false }
        data = bytes; updatedAt = now.timeIntervalSince1970; invalidated = false; failed = false
        return true
    }
    func unavailable(ticket: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard ticket == revision else { return }
        failed = true; invalidated = true
    }
    func envelope(now: Date = Date()) -> [String: Any] {
        lock.lock()
        let bytes = data, timestamp = updatedAt, pending = invalidated, unavailable = failed
        lock.unlock()
        let catalog = bytes.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let freshSummary = TDBAWSStatusModel.summary(catalog, now: now)
        let age = timestamp.map { now.timeIntervalSince1970 - $0 }
        let state: String
        if unavailable { state = "unavailable" }
        else if bytes == nil { state = "loading" }
        else if pending || age.map({ !$0.isFinite || $0 < -1 || $0 > maximumAge }) != false { state = "stale" }
        else if freshSummary["state"] as? String == "unavailable" { state = "unavailable" }
        else { state = "ready" }
        var result: [String: Any] = ["state": state, "stale": state != "ready", "catalog": catalog,
            "summary": state == "ready" ? freshSummary : TDBAWSStatusModel.fallback(state: state, counts: freshSummary)]
        if let timestamp { result["updatedAt"] = timestamp }
        return result
    }

    // Never retain unknown fields from a service response. In particular the
    // credential-process payload and authentication tokens cannot enter status.
    private static func metadata(_ raw: [String: Any]) -> [String: Any] {
        func fields(_ value: [String: Any], _ keys: [String]) -> [String: Any] {
            value.filter { keys.contains($0.key) }
        }
        let profileKeys = ["id", "name", "kind", "region", "ssoStartURL", "ssoRegion", "accountID", "roleName", "loginSession", "ssoSessionName"]
        func profile(_ value: Any?) -> [String: Any]? { (value as? [String: Any]).map { fields($0, profileKeys) } }
        var safe: [String: Any] = [:]
        for key in ["configuredProfileIDs", "localProfileNames", "phase", "sourceStatus", "signInProfile", "signInProfiles", "signInAttempt", "sources"] { safe[key] = raw[key] }
        if let profiles = raw["profiles"] as? [[String: Any]] { safe["profiles"] = profiles.map { fields($0, profileKeys) } }
        for key in ["accounts", "installed"] {
            if let entries = raw[key] as? [[String: Any]] {
                let allowed = key == "installed" ? ["profileId", "targetName", "source"]
                    : ["id", "profileId", "roleId", "sourceName", "sourceNames", "incomingSourceNames", "incomingAvailable", "incomingExpires", "profileNames", "expires", "local", "available", "status", "accountID", "principalARN"]
                safe[key] = entries.map { value -> [String: Any] in
                    var item = fields(value, allowed); item["descriptor"] = profile(value["descriptor"]); return item
                }
            }
        }
        for key in ["authentication", "sourceChecks"] {
            if let entries = raw[key] as? [String: [String: Any]] {
                safe[key] = entries.mapValues { fields($0, key == "authentication" ? ["state", "sessionName", "expiresAt"] : ["state", "checkedAt", "expiresAt", "needsSharedRenewal"]) }
            }
        }
        return safe
    }
}
