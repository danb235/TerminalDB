import Foundation

private final class AWSTestSecrets: SharedAWSSecrets {
    var values: [String: Data] = [:]
    func read(_ id: String) throws -> Data {
        guard let bytes = values[id] else { throw PeerFailure("Synthetic AWS credentials missing.") }; return bytes
    }
    func write(_ value: Data, id: String) throws {
        guard values[id] == nil || values[id] == value else { throw PeerFailure("Synthetic AWS credential conflict.") }
        values[id] = value
    }
    func remove(_ id: String) { values.removeValue(forKey: id) }
}

private final class AWSTestClock {
    var time = floor(Date().timeIntervalSince1970)
}

enum SharedAWSTests {
    static func run(root: URL) throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool) throws {
            guard try condition() else { throw PeerFailure("A shared AWS regression failed after \(checks) checks.") }; checks += 1
        }
        func rejected(_ action: () throws -> Void) -> Bool { do { try action(); return false } catch { return true } }
        let clock = AWSTestClock()
        let sourceA = AWSTestSecrets(), sourceB = AWSTestSecrets(), sourceC = AWSTestSecrets()
        let a = SharedAWSStore(root: root.appendingPathComponent("a"), secrets: sourceA, machine: "fixture-a", now: { clock.time })
        let b = SharedAWSStore(root: root.appendingPathComponent("b"), secrets: sourceB, machine: "fixture-b", now: { clock.time })
        let c = SharedAWSStore(root: root.appendingPathComponent("c"), secrets: sourceC, machine: "fixture-c", now: { clock.time })
        let profile = AWSProfileDescriptor(name: "Fixture Work", kind: "sso", region: "us-east-1",
            ssoStartURL: "https://fixture.awsapps.com/start", ssoRegion: "us-east-1", accountID: "111111111111", roleName: "Reader", ssoSessionName: "fixture")
        let assumed = "arn:aws:sts::111111111111:assumed-role/AWSReservedSSO_Reader_0123456789abcdef/fixture-user"
        let principal = "arn:aws:iam::111111111111:role/AWSReservedSSO_Reader_0123456789abcdef"
        func keys(_ label: String, expires: Double? = nil) -> AWSRoleCredentials {
            AWSRoleCredentials(accessKeyId: "tdb-test-access-" + label, secretAccessKey: "tdb-test-secret-" + String(repeating: label, count: 24),
                sessionToken: "tdb-test-session-" + String(repeating: label, count: 48), expiration: expires ?? clock.time + 3_600)
        }
        let firstKeys = keys("a"), secondKeys = keys("b")
        let process = firstKeys.processOutput()
        try check(try AWSRoleCredentials(process: process, now: clock.time) == firstKeys)
        var malformedProcess = process; malformedProcess.removeValue(forKey: "SessionToken")
        try check(rejected { _ = try AWSRoleCredentials(process: malformedProcess, now: clock.time) })
        malformedProcess = process; malformedProcess["Version"] = true
        try check(rejected { _ = try AWSRoleCredentials(process: malformedProcess, now: clock.time) })
        malformedProcess = process; malformedProcess["Version"] = 2
        try check(rejected { _ = try AWSRoleCredentials(process: malformedProcess, now: clock.time) })
        malformedProcess = process; malformedProcess["Expiration"] = "not-a-date"
        try check(rejected { _ = try AWSRoleCredentials(process: malformedProcess, now: clock.time) })
        try check(rejected { try keys("x", expires: clock.time - 1).validate(now: clock.time) })
        try check(rejected { try keys("x", expires: clock.time + 43_501).validate(now: clock.time) })
        var controlKeys = keys("x"); controlKeys.sessionToken += "\n"
        try check(rejected { try controlKeys.validate(now: clock.time) })
        var genuineLooking = keys("x"); genuineLooking.accessKeyId = "ASIA0000000000000000"
        try check(rejected { try genuineLooking.validate(now: clock.time, syntheticOnly: true) })
        try check(try SharedAWSStore.canonicalPrincipal(assumed).arn == principal)
        try check(try SharedAWSStore.identity(profile: profile, principalARN: assumed) == SharedAWSStore.identity(profile: profile, principalARN: principal))
        try check(rejected { _ = try SharedAWSStore.canonicalPrincipal("arn:aws:sts::111111111111:assumed-role//bad") })
        try check(rejected { _ = try a.publish(profile: profile, principalARN: "arn:aws:iam::222222222222:role/AWSReservedSSO_Reader_0123456789abcdef", credentials: firstKeys) })
        try check(rejected { _ = try a.publish(profile: profile, principalARN: "arn:aws:iam::111111111111:role/AWSReservedSSO_Administrator_0123456789abcdef", credentials: firstKeys) })
        try check(rejected { _ = try a.publish(profile: profile, principalARN: "arn:aws:iam::111111111111:root", credentials: firstKeys) })
        let login = AWSProfileDescriptor(name: "Fixture Login", kind: "login", loginSession: "arn:aws:iam::111111111111:user/fixture")
        try check(rejected { _ = try a.publish(profile: login, principalARN: "arn:aws:iam::111111111111:user/other", credentials: firstKeys) })

        let role = try a.publish(profile: profile, principalARN: assumed, credentials: firstKeys, sourceName: "Fixture A")
        let first = try a.exportBundle()
        let writer = try a.load().writer
        let metadata = try Data(contentsOf: a.root.appendingPathComponent("shared-aws.json"))
        try check([firstKeys.accessKeyId, firstKeys.secretAccessKey, firstKeys.sessionToken].allSatisfy { metadata.range(of: Data($0.utf8)) == nil })
        let attributes = try FileManager.default.attributesOfItem(atPath: a.root.appendingPathComponent("shared-aws.json").path)
        try check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let restarted = SharedAWSStore(root: a.root, secrets: sourceA, machine: "fixture-a", now: { clock.time })
        try check(try restarted.credentials(for: role) == firstKeys && restarted.load().writer == writer)
        try check(try b.catalog().isEmpty)
        try b.importBundle(first); try c.importBundle(b.exportBundle())
        try check(try b.credentials(forProfile: profile.id) == firstKeys && c.credentials(for: role) == firstKeys)
        try check(try a.digest() == b.digest() && b.digest() == c.digest())
        let row = try b.catalog().first!
        try check(row["profileId"] as? String == profile.id && row["roleId"] as? String == role && row["available"] as? Bool == true)
        try check(row["local"] as? Bool == false && row["sourceName"] as? String == "Fixture A" && row["expires"] as? Double == firstKeys.expiration)
        try check((row["descriptor"] as? [String: Any])?["name"] as? String == profile.name)
        try check(try b.profiles() == [profile])

        // Metadata surviving a missing Keychain copy must trigger automatic
        // exchange and allow an equal source revision to restore that copy.
        let credentialID = try b.load().sources[writer]!.roles[role]!.credential
        sourceB.remove(credentialID)
        try check(rejected { _ = try b.credentials(for: profile.id) })
        try check(try a.digest() != b.digest())
        try b.importBundle(first)
        try check(try b.credentials(for: profile.id) == firstKeys && a.digest() == b.digest())
        let restartedB = SharedAWSStore(root: b.root, secrets: sourceB, machine: "fixture-b", now: { clock.time })
        try check(try restartedB.credentials(for: profile.id) == firstKeys)

        // A receiver keeps an independent copy and can also independently
        // supply this role. Withdrawing A must not erase B's supplied session.
        var otherAlias = profile; otherAlias.name = "Another Local Name"
        let sameRole = try b.publish(profile: otherAlias, principalARN: principal, credentials: secondKeys, sourceName: "Fixture B")
        try check(sameRole == role && (try b.catalog()).count == 1)
        try check(Set((try b.catalog()).first?["profileNames"] as? [String] ?? []) == [profile.name, otherAlias.name])
        try check(Set((try b.catalog()).first?["sourceNames"] as? [String] ?? []) == ["Fixture A", "Fixture B"])
        try c.importBundle(b.exportBundle())
        try a.withdraw(profile.id)
        let withdrawn = try a.exportBundle()
        try b.importBundle(withdrawn); try c.importBundle(b.exportBundle())
        try b.importBundle(first); try c.importBundle(first)
        try check(try b.load().sources[writer]!.roles.isEmpty && c.load().sources[writer]!.roles.isEmpty)
        try check(try b.credentials(for: profile.id) == secondKeys && c.credentials(for: profile.id) == secondKeys)
        try check(try b.catalog().first?["local"] as? Bool == true)
        try check(sourceB.values[credentialID] == nil)
        let bKeys = sourceB.values
        let digestBefore = try b.digest()
        var conflict = try b.exportBundle()
        var sources = conflict["sources"] as! [String: Any]
        var snapshot = sources[writer] as! [String: Any]
        snapshot["sourceName"] = "Conflicting fixture"; sources[writer] = snapshot; conflict["sources"] = sources
        try check(rejected { try b.importBundle(conflict) })
        try check(try b.digest() == digestBefore && sourceB.values == bKeys)

        var wrongIdentity = try b.exportBundle()
        sources = wrongIdentity["sources"] as! [String: Any]
        let writerB = try b.load().writer
        snapshot = sources[writerB] as! [String: Any]
        var roles = snapshot["roles"] as! [String: Any]
        roles[String(repeating: "f", count: 64)] = roles.removeValue(forKey: role)
        snapshot["roles"] = roles; sources[writerB] = snapshot; wrongIdentity["sources"] = sources
        try check(rejected { try c.importBundle(wrongIdentity) })
        var forgedRole = try b.exportBundle()
        sources = forgedRole["sources"] as! [String: Any]
        snapshot = sources[writerB] as! [String: Any]; roles = snapshot["roles"] as! [String: Any]
        var forged = roles.removeValue(forKey: role) as! [String: Any]
        let forgedARN = "arn:aws:iam::111111111111:role/AWSReservedSSO_Administrator_0123456789abcdef"
        let forgedID = try SharedAWSStore.identity(profile: profile, principalARN: forgedARN)
        forged["principalARN"] = forgedARN; forged["id"] = forgedID; roles[forgedID] = forged
        snapshot["roles"] = roles; sources[writerB] = snapshot; forgedRole["sources"] = sources
        try check(rejected { try c.importBundle(forgedRole) })
        var wrongCredential = try b.exportBundle()
        var credentialValues = wrongCredential["credentials"] as! [String: Any]
        let bCredential = try b.load().sources[writerB]!.roles[role]!.credential
        var supplied = credentialValues[bCredential] as! [String: Any]; supplied["SessionToken"] = keys("wrong").sessionToken
        credentialValues[bCredential] = supplied; wrongCredential["credentials"] = credentialValues
        try check(rejected { try c.importBundle(wrongCredential) })
        var authority = try b.exportBundle()
        sources = authority["sources"] as! [String: Any]; snapshot = sources[writerB] as! [String: Any]
        snapshot["revision"] = (try b.load().sources[writerB]!.revision) + 1
        sources[writerB] = snapshot; authority["sources"] = sources
        try check(rejected { try b.importBundle(authority) })

        // The same credential cannot receive a later expiration by appearing
        // from a new source. A genuinely new credential can have a later one.
        let extensionStore = SharedAWSStore(root: root.appendingPathComponent("extension"), secrets: AWSTestSecrets(), now: { clock.time })
        var extended = secondKeys; extended.expiration += 300
        _ = try extensionStore.publish(profile: profile, principalARN: principal, credentials: extended, sourceName: "Fixture Extension")
        try check(rejected { try b.importBundle(extensionStore.exportBundle()) })
        try check(try b.credentials(for: profile.id) == secondKeys)
        let laterKeys = keys("c", expires: clock.time + 7_200)
        _ = try b.publish(profile: profile, principalARN: principal, credentials: laterKeys, sourceName: "Fixture B")
        try c.importBundle(b.exportBundle())
        try check(try c.credentials(for: profile.id) == laterKeys)

        // An offline full withdrawal, including after interface restart,
        // remains authoritative when an older peer snapshot arrives later.
        let beforeWithdrawal = try b.exportBundle()
        try restartedB.withdrawAll()
        try c.importBundle(restartedB.exportBundle()); try c.importBundle(beforeWithdrawal)
        try check(try c.catalog().isEmpty && c.load().sources[writerB]!.roles.isEmpty)
        try check(rejected { _ = try c.credentials(for: profile.id) })

        // Expiration passing during transfer is not a new lifetime. Retain
        // metadata for useful UI, but never install or return expired keys.
        clock.time += 8_000
        let expiredKeys = AWSTestSecrets()
        let expired = SharedAWSStore(root: root.appendingPathComponent("expired"), secrets: expiredKeys, now: { clock.time })
        try expired.importBundle(first)
        try check(try expired.catalog().first?["status"] as? String == "Expired")
        try check(expiredKeys.values.isEmpty && rejected { _ = try expired.credentials(for: role) })
        try check((try expired.exportBundle()["credentials"] as? [String: Any])?.isEmpty == true)
        clock.time -= 8_000

        // A copied metadata directory rotates its local writer instead of
        // allowing two Macs to issue equal revisions for one source.
        let clone = SharedAWSStore(root: a.root, secrets: sourceA, machine: "fixture-clone", now: { clock.time })
        _ = try clone.publish(profile: profile, principalARN: principal, credentials: keys("clone"), sourceName: "Fixture Clone")
        try check(try clone.load().writer != writer && clone.load().sources[writer]!.roles.isEmpty)

        var tooManySources: [String: Any] = [:]
        let oneSnapshot = (first["sources"] as! [String: Any]).values.first!
        for _ in 0...SharedAWSStore.maximumSources { tooManySources[UUID().uuidString] = oneSnapshot }
        try check(rejected { try b.importBundle(["schema": 1, "sources": tooManySources, "credentials": [:]]) })
        var manyRoles: [String: Any] = [:]
        let originalRole = ((oneSnapshot as! [String: Any])["roles"] as! [String: Any]).values.first as! [String: Any]
        for index in 0...SharedAWSStore.maximumEntries {
            let p = AWSProfileDescriptor(name: "Fixture \(index)", kind: "sso", ssoStartURL: profile.ssoStartURL,
                ssoRegion: profile.ssoRegion, accountID: profile.accountID, roleName: "Fixture\(index)")
            let arn = "arn:aws:iam::111111111111:role/Fixture\(index)"
            let id = try SharedAWSStore.identity(profile: p, principalARN: arn)
            var r = originalRole; r["id"] = id; r["principalARN"] = arn; r["credential"] = UUID().uuidString
            r["profile"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p))
            manyRoles[id] = r
        }
        let oversized = ["schema": 1, "sources": [UUID().uuidString: ["revision": 1, "sourceName": "Fixture Limit", "roles": manyRoles]], "credentials": [:]] as [String: Any]
        try check(rejected { try b.importBundle(oversized) })
        try check(rejected { try b.importBundle(["schema": true, "sources": [:], "credentials": [:]]) })
        let booleanSchema = try JSONSerialization.jsonObject(with: Data("{\"schema\":true,\"sources\":{},\"credentials\":{}}".utf8)) as! [String: Any]
        try check(rejected { try b.importBundle(booleanSchema) })

        // A recreated SSO role keeps the configured profile identity but gets
        // a different canonical ARN. Replace this source's prior role; a stale
        // independent source stops blocking the new role once its keys expire.
        let rotation = SharedAWSStore(root: root.appendingPathComponent("rotation"), secrets: AWSTestSecrets(), now: { clock.time })
        _ = try rotation.publish(profile: profile, principalARN: principal, credentials: firstKeys, sourceName: "Fixture Rotation")
        let nextPrincipal = "arn:aws:iam::111111111111:role/AWSReservedSSO_Reader_fedcba9876543210"
        let nextKeys = keys("rotation", expires: clock.time + 7_200)
        let nextRole = try rotation.publish(profile: profile, principalARN: nextPrincipal, credentials: nextKeys, sourceName: "Fixture Rotation")
        try check(try rotation.load().sources.values.flatMap { $0.roles.values }.count == 1)
        try check(try rotation.catalog().first?["roleId"] as? String == nextRole && rotation.credentials(for: profile.id) == nextKeys)
        let conflicted = SharedAWSStore(root: root.appendingPathComponent("conflicted"), secrets: AWSTestSecrets(), now: { clock.time })
        try conflicted.importBundle(first); try conflicted.importBundle(rotation.exportBundle())
        try check(try conflicted.catalog().first?["status"] as? String == "Choose Account Again")
        try check(rejected { _ = try conflicted.credentials(for: profile.id) })
        clock.time += 4_000
        try check(try conflicted.catalog().first?["available"] as? Bool == true && conflicted.credentials(for: profile.id) == nextKeys)
        clock.time -= 4_000
        return checks
    }
}
