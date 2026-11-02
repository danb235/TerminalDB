import Foundation

private final class AccountTestSecrets: SharedAccountSecrets {
    var values: [String: Data] = [:]
    func read(_ id: String) throws -> Data {
        guard let value = values[id] else { throw PeerFailure("Synthetic credential missing.") }; return value
    }
    func write(_ value: Data, id: String) throws {
        if let old = values[id], old != value { throw PeerFailure("Synthetic credential conflict.") }
        values[id] = value
    }
    func remove(_ id: String) { values.removeValue(forKey: id) }
}

enum SharedAccountTests {
    static func run(root: URL) throws -> Int {
        var count = 0
        func check(_ value: @autoclosure () throws -> Bool) throws {
            guard try value() else { throw PeerFailure("A shared account regression failed after \(count) checks.") }; count += 1
        }
        func rejected(_ action: () throws -> Void) -> Bool { do { try action(); return false } catch { return true } }
        let keysA = AccountTestSecrets(), keysB = AccountTestSecrets(), keysC = AccountTestSecrets()
        let a = SharedAccountStore(root: root.appendingPathComponent("a"), secrets: keysA)
        let b = SharedAccountStore(root: root.appendingPathComponent("b"), secrets: keysB)
        let c = SharedAccountStore(root: root.appendingPathComponent("c"), secrets: keysC)
        let token1 = Data(("tdb-test-" + String(repeating: "a", count: 96)).utf8)
        let token2 = Data(("tdb-test-" + String(repeating: "b", count: 96)).utf8)
        let token3 = Data(("tdb-test-" + String(repeating: "c", count: 96)).utf8)
        let expiry = Date().addingTimeInterval(10000).timeIntervalSince1970
        let id = try a.save(label: "个人", email: "example@example.invalid", organization: "", plan: "Max", token: token1, expires: expiry, binding: "local-profile")
        let first = try a.exportBundle()
        let bytes = try Data(contentsOf: a.root.appendingPathComponent("shared-accounts.json"))
        try check(bytes.range(of: token1) == nil)
        try check(try a.load().bindings["local-profile"] == id)
        let restartedA = SharedAccountStore(root: a.root, secrets: keysA)
        try check(try restartedA.token(for: id) == token1)
        // A new account created off the LAN is durable before any connection.
        try check(try b.load().accounts.isEmpty)
        try b.importBundle(first)
        try c.importBundle(b.exportBundle())
        try check(try b.token(for: id) == token1 && c.token(for: id) == token1)
        try check(try b.load().accounts.count == 1 && c.load().accounts.count == 1)
        let key = try b.save(label: "Personal", email: "Example@Example.invalid", organization: "", plan: "Max", token: token2, expires: expiry)
        try check(key == id)
        let offlineUpdate = try b.exportBundle()
        try a.remove(id)
        let removal = try a.exportBundle()
        try b.importBundle(removal)
        try a.importBundle(offlineUpdate)
        try check(try SharedAccountStore.winner(a.load().accounts[id]!)?.removed == true)
        try check(try SharedAccountStore.winner(b.load().accounts[id]!)?.removed == true)
        try check(rejected { _ = try a.token(for: id) } && rejected { _ = try b.token(for: id) })
        try a.importBundle(first); try b.importBundle(first)
        try check(rejected { _ = try a.token(for: id) } && rejected { _ = try b.token(for: id) })
        try c.importBundle(removal)
        try check(rejected { _ = try c.token(for: id) })
        let deletedBytes = try JSONSerialization.data(withJSONObject: a.exportBundle())
        try check(!String(decoding: deletedBytes, as: UTF8.self).contains(token1.base64EncodedString()))
        // Explicit re-authorization after observing removal is different from
        // an old offline token arriving late, and may restore the account.
        _ = try a.save(label: "Renewed", email: "example@example.invalid", organization: "", plan: "Max", token: token3, expires: expiry)
        try b.importBundle(a.exportBundle()); try c.importBundle(b.exportBundle())
        try check(try b.token(for: id) == token3 && c.token(for: id) == token3)
        try b.importBundle(first)
        try check(try b.token(for: id) == token3)
        let before = try JSONEncoder.sorted.encode(b.load())
        var malformed = try a.exportBundle()
        var malformedAccounts = malformed["accounts"] as! [String: Any]
        malformedAccounts[String(repeating: "f", count: 64)] = malformedAccounts.removeValue(forKey: id)
        malformed["accounts"] = malformedAccounts
        try check(rejected { try b.importBundle(malformed) })
        try check(try JSONEncoder.sorted.encode(b.load().accounts) == JSONEncoder.sorted.encode(a.load().accounts))
        var conflict = try a.exportBundle()
        var conflictAccounts = conflict["accounts"] as! [String: Any]
        var versions = conflictAccounts[id] as! [[String: Any]]
        versions[0]["label"] = "Conflicting revision"; conflictAccounts[id] = versions; conflict["accounts"] = conflictAccounts
        try check(rejected { try b.importBundle(conflict) })
        try check(try JSONEncoder.sorted.encode(b.load()) == before)
        var expired = try a.exportBundle(); var expiredAccounts = expired["accounts"] as! [String: Any]; versions = expiredAccounts[id] as! [[String: Any]]
        versions[0]["expires"] = Date().timeIntervalSince1970 - 1; expiredAccounts[id] = versions; expired["accounts"] = expiredAccounts
        let d = SharedAccountStore(root: root.appendingPathComponent("d"), secrets: AccountTestSecrets())
        try d.importBundle(expired)
        try check(rejected { _ = try d.token(for: id) })
        // Distinct organizations sharing an email do not collapse into one row.
        let orgID = try a.save(label: "Work", email: "example@example.invalid", organization: "organization-2", plan: "Team", token: token1, expires: expiry)
        try check(orgID != id)
        try check(try a.load().accounts.count == 2)
        var tooMany: [String: Any] = [:]
        for i in 0...SharedAccountStore.maximumAccounts { tooMany[String(i)] = [] }
        try check(rejected { try b.importBundle(["accounts": tooMany]) })
        // A directory snapshot can withdraw a normal local login, including
        // after a disconnected peer returns with the previous snapshot.
        let descriptor = ["id": id, "email": "example@example.invalid", "label": "Personal", "organization": ""]
        try check(try a.updateDirectory([descriptor]))
        let withDirectory = try a.exportBundle()
        try b.importBundle(withDirectory)
        try check(try b.load().directory?.values.contains(where: { $0.accounts == [descriptor] }) == true)
        try check(try a.updateDirectory([]))
        let withdrawn = try a.exportBundle()
        try b.importBundle(withdrawn); try b.importBundle(withDirectory)
        try check(try b.load().directory?.values.allSatisfy({ $0.accounts.isEmpty }) == true)
        // Concurrent updates converge independently of delivery order.
        let e = SharedAccountStore(root: root.appendingPathComponent("e"), secrets: AccountTestSecrets())
        let f = SharedAccountStore(root: root.appendingPathComponent("f"), secrets: AccountTestSecrets())
        try e.importBundle(first); try f.importBundle(first)
        _ = try e.save(label: "E", email: "example@example.invalid", organization: "", plan: "Max", token: token2, expires: expiry)
        _ = try f.save(label: "F", email: "example@example.invalid", organization: "", plan: "Max", token: token3, expires: expiry)
        let fromE = try e.exportBundle(), fromF = try f.exportBundle()
        try e.importBundle(fromF); try f.importBundle(fromE)
        try check(try JSONEncoder.sorted.encode(e.load().accounts) == JSONEncoder.sorted.encode(f.load().accounts))
        try check(try e.token(for: id) == f.token(for: id))
        try check(SharedAccountStore.identity(email: "Te\u{301}st@example.invalid", organization: "") == SharedAccountStore.identity(email: "Tést@example.invalid", organization: ""))
        // App Support migrations preserve account history but rotate the local
        // writer, preventing a cloned Mac from issuing equal-vector updates.
        let cloneRoot = root.appendingPathComponent("clone")
        let original = SharedAccountStore(root: cloneRoot, secrets: AccountTestSecrets(), machine: "first-mac")
        _ = try original.updateDirectory([])
        let writer = try original.load().writer
        let clone = SharedAccountStore(root: cloneRoot, secrets: AccountTestSecrets(), machine: "second-mac")
        _ = try clone.updateDirectory([])
        try check(try clone.load().writer != writer)
        let cloneWriter = try clone.load().writer
        _ = try clone.updateDirectory([])
        try check(try clone.load().writer == cloneWriter)
        try check(!(try clone.exportBundle()).keys.contains("machine"))
        // Metadata-only backup restoration cannot mark an unchanged token as
        // already installed. A subsequent approved import repairs its copy.
        let restoredKeys = AccountTestSecrets()
        let restored = SharedAccountStore(root: root.appendingPathComponent("restored"), secrets: restoredKeys)
        try FileManager.default.createDirectory(at: restored.root, withIntermediateDirectories: true)
        try Data(contentsOf: a.root.appendingPathComponent("shared-accounts.json")).write(to: restored.root.appendingPathComponent("shared-accounts.json"))
        try check(rejected { _ = try restored.token(for: id) })
        try restored.importBundle(a.exportBundle())
        try check(try restored.token(for: id) == a.token(for: id))
        return count
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder }
}
