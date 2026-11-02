import Foundation
import Security
import CryptoKit
import Darwin

// Only reusable Claude Code credentials enter this store. Normal Claude login
// and refresh credentials remain owned by the unmodified Claude Code client.
// The JSON document contains metadata and causal history, never bearer tokens.
struct SharedAccountVersion: Codable, Equatable {
    var clock: [String: UInt64]
    var credential: String
    var label: String
    var email: String
    var organization: String
    var plan: String
    var expires: Double
    var removed: Bool
    var digest: String

    func dominates(_ other: Self) -> Bool {
        other.clock.allSatisfy { (clock[$0.key] ?? 0) >= $0.value } && clock != other.clock
    }
    var rank: String { credential }
    func validate() throws {
        guard !clock.isEmpty, clock.count <= 128,
              clock.allSatisfy({ UUID(uuidString: $0.key) != nil && $0.value > 0 && $0.value <= 1_000_000_000 }),
              UUID(uuidString: credential) != nil,
              !label.isEmpty, label.utf8.count <= 160,
              !email.isEmpty, email.utf8.count <= 320,
              organization.utf8.count <= 160, plan.utf8.count <= 80,
              expires.isFinite, expires > 0, expires < 32_503_680_000,
              digest.count == 64, digest.allSatisfy({ $0.isHexDigit }),
              ![label, email, organization, plan].contains(where: { $0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) })
        else { throw PeerFailure("The shared account description is invalid.") }
    }
}

struct SharedAccountDocument: Codable {
    var writer = UUID().uuidString
    // Local only: a copied Application Support directory must not make two
    // different Macs issue revisions under the same writer identity.
    var machine: String?
    var accounts: [String: [SharedAccountVersion]] = [:]
    var bindings: [String: String] = [:]
    var directory: [String: SharedAccountDirectory]?
}

struct SharedAccountDirectory: Codable, Equatable {
    var revision: UInt64
    var name: String
    var accounts: [[String: String]]
}

protocol SharedAccountSecrets {
    func read(_ id: String) throws -> Data
    func write(_ value: Data, id: String) throws
    func remove(_ id: String)
}

private struct SharedAccountKeychain: SharedAccountSecrets {
    private func query(_ id: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: "com.terminaldb.claude.shared", kSecAttrAccount: id,
         kSecAttrSynchronizable: false]
    }
    func read(_ id: String) throws -> Data {
        var q = query(id); q[kSecReturnData] = true; q[kSecMatchLimit] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &value) == errSecSuccess, let data = value as? Data else {
            throw PeerFailure("Unlock this Mac’s Keychain to use its shared Claude sign-in.")
        }
        return data
    }
    func write(_ value: Data, id: String) throws {
        var q = query(id); q[kSecValueData] = value
        q[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let result = SecItemAdd(q as CFDictionary, nil)
        if result == errSecDuplicateItem {
            guard try read(id) == value else { throw PeerFailure("A shared credential identity conflicted. Sign in again.") }
        } else if result != errSecSuccess {
            throw PeerFailure("macOS could not save the shared sign-in. Unlock Keychain and try again.")
        }
    }
    func remove(_ id: String) { SecItemDelete(query(id) as CFDictionary) }
}

// QA may persist synthetic credentials across its disposable helper processes.
// Real credentials are explicitly rejected by this test-only implementation.
private struct SharedAccountFixtureSecrets: SharedAccountSecrets {
    let root: URL
    func read(_ id: String) throws -> Data { try Data(contentsOf: root.appendingPathComponent(id)) }
    func write(_ value: Data, id: String) throws {
        guard String(data: value, encoding: .utf8)?.hasPrefix("tdb-test-") == true else {
            throw PeerFailure("Real sign-ins cannot be used in the disposable account test.")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = root.appendingPathComponent(id)
        try value.write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
    func remove(_ id: String) { try? FileManager.default.removeItem(at: root.appendingPathComponent(id)) }
}

final class SharedAccountStore {
    let root: URL
    let secrets: SharedAccountSecrets
    private let machine: String
    static let maximumAccounts = 128
    init(root: URL = PeerPaths.root, secrets: SharedAccountSecrets? = nil, machine: String? = nil) {
        self.root = root
        var host = UUID().uuid
        var timeout = timespec(tv_sec: 1, tv_nsec: 0)
        let identified = gethostuuid(&host, &timeout) == 0
        self.machine = machine ?? (identified ? PeerProtocol.fingerprint(Data(UUID(uuid: host).uuidString.utf8)) : "")
        if let secrets { self.secrets = secrets }
        else if ProcessInfo.processInfo.environment["TERMINALDB_PEER_QA"] == "1" &&
                    ProcessInfo.processInfo.environment["TERMINALDB_PEER_EPHEMERAL_IDENTITY"] == "1" {
            self.secrets = SharedAccountFixtureSecrets(root: root.appendingPathComponent("fixture-credentials"))
        } else { self.secrets = SharedAccountKeychain() }
    }
    func load() throws -> SharedAccountDocument {
        let file = root.appendingPathComponent("shared-accounts.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return SharedAccountDocument() }
        let bytes = try Data(contentsOf: file)
        guard bytes.count <= 2_000_000 else { throw PeerFailure("The shared account catalog exceeded its limit.") }
        return try JSONDecoder().decode(SharedAccountDocument.self, from: bytes)
    }
    private func locked<T>(_ action: (inout SharedAccountDocument) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(root.appendingPathComponent("shared-accounts.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw PeerFailure("The shared account catalog could not be opened.") }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw PeerFailure("The shared account catalog is busy.") }
        defer { flock(fd, LOCK_UN) }
        var doc = try load()
        if !machine.isEmpty {
            if let previous = doc.machine, previous != machine { doc.writer = UUID().uuidString }
            doc.machine = machine
        }
        let previousSecrets = Set(doc.accounts.values.flatMap { $0.filter { !$0.removed }.map(\.credential) })
        let result = try action(&doc)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(doc)
        guard data.count <= 2_000_000 else { throw PeerFailure("Too many shared account changes are pending.") }
        let file = root.appendingPathComponent("shared-accounts.json")
        if (try? Data(contentsOf: file)) != data {
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        let retainedSecrets = Set(doc.accounts.values.flatMap { values in
            Self.winner(values)?.removed == true ? [] : values.filter { !$0.removed }.map(\.credential)
        })
        for id in previousSecrets.subtracting(retainedSecrets) { secrets.remove(id) }
        return result
    }
    static func identity(email: String, organization: String) -> String {
        func normalized(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().precomposedStringWithCanonicalMapping }
        return PeerProtocol.fingerprint(Data((normalized(email) + "\n" + normalized(organization)).utf8))
    }
    private static func checkCapacity(accounts: [String: [SharedAccountVersion]], directory: [String: SharedAccountDirectory]) throws {
        let ids = Set(accounts.keys).union(directory.values.flatMap { $0.accounts.compactMap { $0["id"] } })
        guard ids.count <= maximumAccounts else { throw PeerFailure("The shared account catalog is full.") }
    }
    func updateDirectory(_ accounts: [[String: String]]) throws -> Bool {
        try locked { doc in
            let previous = doc.directory?[doc.writer]
            let name = PeerProtocol.displayName(Host.current().localizedName ?? "Mac")
            guard previous?.accounts != accounts || previous?.name != name else { return false }
            var entries = doc.directory ?? [:]
            guard (previous?.revision ?? 0) < 1_000_000_000 else { throw PeerFailure("The account directory revision limit was reached.") }
            entries[doc.writer] = SharedAccountDirectory(revision: (previous?.revision ?? 0) + 1, name: name, accounts: accounts)
            try Self.checkCapacity(accounts: doc.accounts, directory: entries)
            doc.directory = entries
            return true
        }
    }
    static func winner(_ versions: [SharedAccountVersion]) -> SharedAccountVersion? {
        // A concurrent removal wins. A new sign-in can restore an account only
        // after it has observed that removal, so an offline Mac cannot undo it.
        (versions.filter(\.removed).isEmpty ? versions : versions.filter(\.removed)).max { $0.rank < $1.rank }
    }
    static func merge(_ a: [SharedAccountVersion], _ b: [SharedAccountVersion]) throws -> [SharedAccountVersion] {
        var combined = a
        for v in b {
            try v.validate()
            if let old = combined.first(where: { $0.clock == v.clock }) {
                guard old == v else { throw PeerFailure("Conflicting account revisions were rejected.") }
            } else { combined.append(v) }
        }
        let result = combined.filter { v in !combined.contains { $0.dominates(v) } }.sorted { $0.rank < $1.rank }
        guard result.count <= 16 else { throw PeerFailure("Too many concurrent account changes. Reconnect your Macs before trying again.") }
        return result
    }
    private func nextClock(_ versions: [SharedAccountVersion], writer: String) throws -> [String: UInt64] {
        var clock: [String: UInt64] = [:]
        for v in versions { for (key, value) in v.clock { clock[key] = max(clock[key] ?? 0, value) } }
        guard (clock[writer] ?? 0) < 1_000_000_000 else { throw PeerFailure("The account revision limit was reached.") }
        clock[writer, default: 0] += 1
        return clock
    }
    @discardableResult func save(label: String, email: String, organization: String, plan: String,
                                token: Data, expires: Double, binding: String? = nil) throws -> String {
        guard (32...4096).contains(token.count), expires > Date().timeIntervalSince1970 else {
            throw PeerFailure("A valid reusable Claude Code sign-in is required.")
        }
        let id = Self.identity(email: email, organization: organization)
        return try locked { doc in
            guard doc.accounts[id] != nil || doc.accounts.count < Self.maximumAccounts else { throw PeerFailure("The shared account limit was reached.") }
            let old = doc.accounts[id] ?? []
            let value = SharedAccountVersion(clock: try nextClock(old, writer: doc.writer), credential: UUID().uuidString,
                label: label, email: email, organization: organization, plan: plan, expires: expires, removed: false,
                digest: PeerProtocol.fingerprint(token))
            try value.validate()
            var proposed = doc.accounts; proposed[id] = [value]
            try Self.checkCapacity(accounts: proposed, directory: doc.directory ?? [:])
            try secrets.write(token, id: value.credential)
            doc.accounts[id] = [value]
            if let binding { doc.bindings[binding] = id }
            // Retire superseded secrets only after the metadata commit. The
            // small unreachable Keychain item on an interrupted commit is safe.
            return id
        }
    }
    func remove(_ id: String) throws {
        try locked { doc in
            guard let versions = doc.accounts[id], var value = Self.winner(versions) else { return }
            value.clock = try nextClock(versions, writer: doc.writer)
            value.credential = UUID().uuidString; value.removed = true
            doc.accounts[id] = [value]
        }
    }
    func exportBundle() throws -> [String: Any] {
        // Do not persist or cache this result. It is used only on a mutually
        // authenticated connection after both devices enabled account sync.
        let doc = try load()
        var result: [String: Any] = [:]
        for (id, versions) in doc.accounts {
            let removed = Self.winner(versions)?.removed == true
            result[id] = try versions.map { v -> [String: Any] in
                var item = try JSONSerialization.jsonObject(with: JSONEncoder().encode(v)) as! [String: Any]
                if !v.removed && !removed {
                    let value = try secrets.read(v.credential)
                    guard PeerProtocol.fingerprint(value) == v.digest else { throw PeerFailure("The shared sign-in needs repair.") }
                    item["token"] = value.base64EncodedString()
                }
                return item
            }
        }
        let bundle: [String: Any] = ["accounts": result, "directory": try JSONSerialization.jsonObject(with: JSONEncoder().encode(doc.directory ?? [:]))]
        guard try JSONSerialization.data(withJSONObject: bundle).count <= 4_000_000 else { throw PeerFailure("The shared account transfer exceeded its limit.") }
        return bundle
    }
    func importBundle(_ bundle: [String: Any]) throws {
        guard let records = bundle["accounts"] as? [String: Any], records.count <= Self.maximumAccounts,
              try JSONSerialization.data(withJSONObject: bundle).count <= 4_000_000 else { throw PeerFailure("The shared account transfer exceeded its limit.") }
        try locked { doc in
            let directories = try JSONDecoder().decode([String: SharedAccountDirectory].self, from: JSONSerialization.data(withJSONObject: bundle["directory"] ?? [:]))
            guard directories.count <= 128, directories.values.reduce(0, { $0 + $1.accounts.count }) <= 1024 else { throw PeerFailure("The account directory exceeded its limit.") }
            var directory = doc.directory ?? [:]
            for (writer, snapshot) in directories {
                guard UUID(uuidString: writer) != nil, snapshot.revision > 0, snapshot.revision <= 1_000_000_000,
                      snapshot.name == PeerProtocol.displayName(snapshot.name), snapshot.accounts.count <= 128 else { throw PeerFailure("The account directory is invalid.") }
                for item in snapshot.accounts {
                    guard let email = item["email"], let label = item["label"], let id = item["id"],
                          email.utf8.count <= 320, label.utf8.count <= 160, !email.isEmpty, !label.isEmpty,
                          id == Self.identity(email: email, organization: item["organization"] ?? ""),
                          item.values.allSatisfy({ $0.utf8.count <= 320 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else { throw PeerFailure("The account directory contains an invalid account.") }
                }
                if let old = directory[writer], old.revision == snapshot.revision, old != snapshot { throw PeerFailure("Conflicting account directory revisions were rejected.") }
                if (directory[writer]?.revision ?? 0) < snapshot.revision { directory[writer] = snapshot }
            }
            guard directory.count <= 128, directory.values.reduce(0, { $0 + $1.accounts.count }) <= 1024 else { throw PeerFailure("The account directory is full.") }
            var proposed = doc.accounts
            var additions: [(String, Data)] = []
            for (id, object) in records {
                guard id.count == 64, id.allSatisfy({ $0.isHexDigit }), let items = object as? [[String: Any]],
                      !items.isEmpty, items.count <= 16 else { throw PeerFailure("The shared account catalog is invalid.") }
                let versions = try items.map { item -> SharedAccountVersion in
                    let value = try JSONDecoder().decode(SharedAccountVersion.self, from: JSONSerialization.data(withJSONObject: item))
                    try value.validate()
                    guard id == Self.identity(email: value.email, organization: value.organization) else { throw PeerFailure("The shared account identity did not match.") }
                    return value
                }
                let merged = try Self.merge(proposed[id] ?? [], versions)
                for value in merged where Self.winner(merged)?.removed != true && !value.removed {
                    // Metadata may survive a device migration or Keychain
                    // repair. An unchanged revision must still restore its
                    // credential when an approved peer supplies it again.
                    guard let encoded = items.first(where: { $0["credential"] as? String == value.credential })?["token"] as? String else {
                        guard (proposed[id] ?? []).contains(value) else { throw PeerFailure("The reusable sign-in was incomplete.") }
                        continue
                    }
                    guard let data = Data(base64Encoded: encoded), (32...4096).contains(data.count),
                          PeerProtocol.fingerprint(data) == value.digest else { throw PeerFailure("The reusable sign-in was incomplete.") }
                    additions.append((value.credential, data))
                }
                proposed[id] = merged
            }
            guard proposed.count <= Self.maximumAccounts else { throw PeerFailure("The shared account catalog is full.") }
            try Self.checkCapacity(accounts: proposed, directory: directory)
            for (id, value) in additions { try secrets.write(value, id: id) }
            doc.accounts = proposed
            doc.directory = directory
        }
    }
    func token(for id: String) throws -> Data {
        guard let value = try Self.winner(load().accounts[id] ?? []), !value.removed else { throw PeerFailure("This shared account has been removed.") }
        guard value.expires > Date().timeIntervalSince1970 else { throw PeerFailure("This shared sign-in expired. Renew it once from Accounts & Usage, then start Claude again.") }
        let data = try secrets.read(value.credential)
        guard PeerProtocol.fingerprint(data) == value.digest else { throw PeerFailure("This shared sign-in needs repair.") }
        return data
    }
}

@objc(TDBSharedAccounts)
public final class TDBSharedAccounts: NSObject {
    private static let cacheLock = NSLock()
    private static var cachedKey = ""
    private static var cachedValue: SharedAccountDocument?
    private static func document() -> SharedAccountDocument? {
        guard !ProcessInfo.processInfo.arguments.contains("--self-test") else { return nil }
        cacheLock.lock(); defer { cacheLock.unlock() }
        let file = PeerPaths.file("shared-accounts.json")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path) else { cachedValue = nil; cachedKey = ""; return nil }
        let key = file.path + ":" + String((attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0) + ":" + String(describing: attributes[.systemFileNumber])
        if key != cachedKey {
            cachedValue = try? SharedAccountStore().load(); cachedKey = key
        }
        return cachedValue
    }
    @objc(identityForEmail:organization:)
    public static func identity(email: String, organization: String) -> String { SharedAccountStore.identity(email: email, organization: organization) }
    @objc(accountForConfigDirectory:)
    public static func accountForConfigDirectory(_ directory: String) -> String {
        if ProcessInfo.processInfo.arguments.contains("--self-test") { return "" }
        let profile = URL(fileURLWithPath: directory).deletingLastPathComponent()
        let file = profile.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("profiles.json")
        guard let data = try? Data(contentsOf: file), data.count < 1_000_000,
              let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profiles = doc["profiles"] as? [[String: Any]],
              let id = profiles.first(where: { $0["id"] as? String == profile.lastPathComponent })?["sharedID"] as? String,
              id.count == 64, id.allSatisfy({ $0.isHexDigit }) else { return "" }
        return id
    }
    @objc public static func directoryCatalog() -> [[String: Any]] {
        if ProcessInfo.processInfo.arguments.contains("--self-test") { return [] }
        guard let doc = document() else { return [] }
        var catalog: [String: [String: Any]] = [:]
        for (_, entry) in (doc.directory ?? [:]).sorted(by: { $0.key < $1.key }) {
            for item in entry.accounts {
                guard let id = item["id"] else { continue }
                var value = catalog[id] ?? item.reduce(into: [String: Any]()) { $0[$1.key] = $1.value }
                var locations = value["locations"] as? [String] ?? []
                if !locations.contains(entry.name) { locations.append(entry.name) }
                value["locations"] = locations.sorted(); catalog[id] = value
            }
        }
        return catalog.values.sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }
    }
    @objc public static func catalog() -> [[String: Any]] {
        if ProcessInfo.processInfo.arguments.contains("--self-test") { return [] }
        guard let doc = document() else { return [] }
        return doc.accounts.compactMap { id, versions in
            guard let value = SharedAccountStore.winner(versions), !value.removed else { return nil }
            return ["id": id, "label": value.label, "email": value.email, "plan": value.plan,
                    "expires": value.expires, "organization": value.organization,
                    "ready": value.expires > Date().timeIntervalSince1970]
        }.sorted { ($0["label"] as? String ?? "") < ($1["label"] as? String ?? "") }
    }
    @objc public static func bindings() -> [String: String] { document()?.bindings ?? [:] }
    @objc public static func removedIDs() -> [String] {
        document()?.accounts.compactMap { id, values in SharedAccountStore.winner(values)?.removed == true ? id : nil } ?? []
    }
}
