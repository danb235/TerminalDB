import Foundation

enum AWSStatusTests {
    static func run() throws -> Int {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool) throws {
            guard value() else { throw PeerFailure("An AWS cached status regression failed after \(checks) checks.") }
            checks += 1
        }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let expiry = now.timeIntervalSince1970 + 60
        func profile(_ name: String, account: String) -> AWSProfileDescriptor {
            AWSProfileDescriptor(name: name, kind: "sso", region: "us-east-1", ssoStartURL: "https://example.awsapps.com/start",
                                 ssoRegion: "us-east-1", accountID: account, roleName: "ReadOnly", ssoSessionName: "shared-session")
        }
        func object(_ descriptor: AWSProfileDescriptor) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(descriptor)) as! [String: Any]
        }
        let native = profile("native", account: "111111111111"), alias = profile("native-alias", account: "111111111111")
        let receiver = profile("received", account: "222222222222"), incoming = profile("available", account: "333333333333")
        func account(_ descriptor: AWSProfileDescriptor) throws -> [String: Any] {
            ["profileId": descriptor.id, "descriptor": try object(descriptor), "available": true,
             "expires": expiry, "status": "Ready", "sourceNames": ["Fixture Mac"]]
        }
        let catalog: [String: Any] = [
            "profiles": try [object(native), object(alias)], "configuredProfileIDs": [native.id], "sources": [],
            "accounts": try [account(receiver), account(incoming)],
            "installed": [["profileId": receiver.id, "targetName": "received", "descriptor": try object(receiver), "source": false]],
            "sourceChecks": [native.id: ["state": "ready", "checkedAt": now.timeIntervalSince1970, "expiresAt": expiry]],
            "authentication": [native.id: ["state": "expired", "expiresAt": now.timeIntervalSince1970 - 10]]
        ]
        let summary = TDBAWSStatusModel.summary(catalog, now: now)
        try check(summary["configuredCount"] as? Int == 2 && summary["readyCount"] as? Int == 2)
        try check(summary["attentionCount"] as? Int == 0 && summary["state"] as? String == "ready")
        try check(summary["title"] as? String == "AWS · 2 ready")
        // A received but unmapped copy cannot authenticate an unchecked native
        // alias; selecting the correct AWS provider remains an explicit action.
        var unverified = catalog
        unverified["sourceChecks"] = [:]
        unverified["accounts"] = try [account(native), account(receiver), account(incoming)]
        try check(TDBAWSStatusModel.summary(unverified, now: now)["readyCount"] as? Int == 1)
        var nativeSource = unverified
        nativeSource["sources"] = [native.id]
        var incomingNative = try account(native)
        incomingNative["incomingAvailable"] = true; incomingNative["incomingSourceNames"] = ["Fixture Mac"]
        incomingNative["incomingExpires"] = expiry - 30
        nativeSource["accounts"] = try [incomingNative, account(receiver)]
        for checkState in ["ready", "checking", "signInRequired"] {
            nativeSource["sourceChecks"] = [native.id: ["state": checkState, "expiresAt": now.timeIntervalSince1970 - 1]]
            try check(TDBAWSStatusModel.summary(nativeSource, now: now)["readyCount"] as? Int == 1)
        }
        nativeSource["sourceChecks"] = [native.id: ["state": "checking"]]
        try check(TDBAWSStatusModel.summary(nativeSource, now: now)["readyCount"] as? Int == 1)
        let recoveryRow = AWSProfilePresentation.rows(catalog: nativeSource).first { $0.id == native.id }!
        try check(recoveryRow.needsIncomingSourceRecovery(isSource: true, now: now))
        try check(!recoveryRow.needsIncomingSourceRecovery(isSource: true, now: now.addingTimeInterval(31)))
        try check(TDBAWSStatusModel.summary(nativeSource, now: now.addingTimeInterval(31))["readyCount"] as? Int == 1)
        var denied = catalog
        denied["sourceChecks"] = [native.id: ["state": "accessDenied", "expiresAt": expiry]]
        let deniedSummary = TDBAWSStatusModel.summary(denied, now: now)
        try check(deniedSummary["readyCount"] as? Int == 1 && deniedSummary["attentionCount"] as? Int == 1)
        try check(deniedSummary["state"] as? String == "attention")
        try check(deniedSummary["title"] as? String == "AWS · Access denied")
        var renewable = catalog
        renewable["sourceChecks"] = [native.id: ["state": "signInRequired", "expiresAt": expiry]]
        try check(TDBAWSStatusModel.summary(renewable, now: now)["readyCount"] as? Int == 2)
        try check(TDBAWSStatusModel.summary(renewable, now: now)["attentionCount"] as? Int == 1)
        try check(TDBAWSStatusModel.summary(renewable, now: now)["title"] as? String == "AWS · Sign-in needed")
        var network = catalog
        network["sourceChecks"] = [native.id: ["state": "networkUnavailable", "expiresAt": expiry]]
        try check(TDBAWSStatusModel.summary(network, now: now)["readyCount"] as? Int == 2)
        try check(TDBAWSStatusModel.summary(network, now: now)["title"] as? String == "AWS · Connection issue")
        try check(TDBAWSStatusModel.summary(catalog, now: now.addingTimeInterval(61))["readyCount"] as? Int == 0)
        try check(TDBAWSStatusModel.summary([:], now: now)["state"] as? String == "unavailable")
        try check(TDBAWSStatusModel.summary(["profiles": ["invalid"], "accounts": [], "installed": []], now: now)["state"] as? String == "unavailable")
        try check(TDBAWSStatusModel.summary(catalog, now: Date(timeIntervalSince1970: .nan))["state"] as? String == "unavailable")
        let empty: [String: Any] = ["profiles": [], "accounts": [], "installed": []]
        try check(TDBAWSStatusModel.summary(empty, now: now)["configuredCount"] as? Int == 0)
        try check(TDBAWSStatusModel.summary(empty, now: now)["state"] as? String == "empty")

        let cache = SharedAWSStatusCache()
        try check(cache.envelope(now: now)["state"] as? String == "loading")
        try check(cache.replace(catalog, ticket: cache.ticket(), now: now))
        try check(cache.envelope(now: now)["state"] as? String == "ready")
        let pastExpiry = cache.envelope(now: now.addingTimeInterval(61))
        try check((pastExpiry["summary"] as? [String: Any])?["readyCount"] as? Int == 0)
        let stale = cache.envelope(now: now.addingTimeInterval(91))
        try check(stale["state"] as? String == "stale" && stale["stale"] as? Bool == true)
        try check((stale["summary"] as? [String: Any])?["title"] as? String != "AWS · 2 ready")
        try check(cache.envelope(now: now.addingTimeInterval(-2))["state"] as? String == "stale")
        let oldTicket = cache.ticket(); cache.invalidate()
        try check(!cache.replace(catalog, ticket: oldTicket, now: now))
        try check(cache.envelope(now: now)["state"] as? String == "stale")
        cache.unavailable(ticket: cache.ticket())
        try check(cache.envelope(now: now)["state"] as? String == "unavailable")
        try check(TDBAWSStatusModel.fallback(state: "disconnected")["title"] as? String == "AWS · Reconnecting")
        var unexpected = catalog
        unexpected["credentials"] = ["AccessKeyId": "tdb-test-must-not-enter-status"]
        unexpected["authentication"] = [native.id: ["state": "current", "accessToken": "tdb-test-must-not-enter-status"]]
        try check(cache.replace(unexpected, ticket: cache.ticket(), now: now))
        let encoded = try JSONSerialization.data(withJSONObject: cache.envelope(now: now))
        try check(!String(decoding: encoded, as: UTF8.self).contains("tdb-test-must-not-enter-status"))
        try check(cache.envelope(now: now)["loginExpiresAt"] == nil)
        try check(cache.replace(nativeSource, ticket: cache.ticket(), now: now))
        try check(((cache.envelope(now: now)["catalog"] as? [String: Any])?["accounts"] as? [[String: Any]])?.first?["incomingAvailable"] as? Bool == true)
        try check(((cache.envelope(now: now)["catalog"] as? [String: Any])?["accounts"] as? [[String: Any]])?.first?["incomingExpires"] as? Double == expiry - 30)

        var lease = PeerControlLease()
        let generation = lease.acquire("paired-viewer")
        try check(SharedAWSRemotePolicy.controls(attached: true, lease: lease, principal: "paired-viewer", generation: generation))
        try check(!SharedAWSRemotePolicy.controls(attached: false, lease: lease, principal: "paired-viewer", generation: generation))
        try check(!SharedAWSRemotePolicy.controls(attached: true, lease: lease, principal: "other-viewer", generation: generation))
        _ = lease.acquire("new-controller")
        try check(!SharedAWSRemotePolicy.controls(attached: true, lease: lease, principal: "paired-viewer", generation: generation))
        try check(!SharedAWSRemotePolicy.controls(attached: true, lease: lease, principal: "new-controller", generation: nil))
        for operation in ["aws.credentials", "aws.signIn.start", "aws.signIn.cancel", "aws.sync.export", "aws.sync.import", "aws.share"] {
            try check(!SharedAWSRemotePolicy.remoteManagement.contains(operation))
        }
        try check(!SharedAWSRemotePolicy.receiptOperations.contains("aws.credentials"))
        try check(!SharedAWSRemotePolicy.receiptOperations.contains("aws.sync.export"))
        let observer = SharedAWSRemotePolicy.capabilities(local: false, controlling: false)
        try check(observer["canManage"] as? Bool == false && observer["requiresControl"] as? Bool == true)
        let controller = SharedAWSRemotePolicy.capabilities(local: false, controlling: true)
        try check(Set(controller["allowedOperations"] as? [String] ?? []) == SharedAWSRemotePolicy.remoteManagement)
        try check(controller["canSignIn"] as? Bool == false)
        try check(SharedAWSRemotePolicy.capabilities(local: true, controlling: false)["canSignIn"] as? Bool == true)
        let receipts = PeerReceipts()
        receipts.remember(principal: "paired-viewer", request: "one-action", result: ["accepted": true])
        try check(receipts.result(principal: "paired-viewer", request: "one-action")?["accepted"] as? Bool == true)
        try check(receipts.result(principal: "other-viewer", request: "one-action") == nil)
        receipts.remember(principal: "paired-viewer", request: "rejected-action", result: ["code": "control-required"])
        _ = lease.acquire("paired-viewer")
        try check(receipts.result(principal: "paired-viewer", request: "rejected-action")?["code"] as? String == "control-required")
        let flights = PeerRequestFlights()
        let samePrincipalRequest = "paired-viewer:stable-client:pending-action"
        flights.insert(samePrincipalRequest, operation: "aws.use", now: 10)
        flights.expire(samePrincipalRequest, now: 71)
        try check(flights.contains(samePrincipalRequest) && flights.count == 1)
        // A reconnected client presents the same principal/request scope and
        // remains ineligible to enqueue, while another principal stays separate.
        try check(flights.contains("paired-viewer:stable-client:pending-action"))
        try check(!flights.contains("other-viewer:stable-client:pending-action"))
        flights.remove(samePrincipalRequest)
        try check(!flights.contains(samePrincipalRequest) && flights.count == 0)
        flights.insert("read-request", operation: "health.ping", now: 10)
        flights.expire("read-request", now: 69)
        try check(flights.contains("read-request"))
        flights.expire("read-request", now: 71)
        try check(!flights.contains("read-request"))
        return checks
    }
}
