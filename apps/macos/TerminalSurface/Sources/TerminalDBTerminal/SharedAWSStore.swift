import Foundation
import Security
import Darwin

// AWS's process credential schema is deliberately separate from reusable
// subscription sign-ins. Absolute AWS expiration is never rebased on receipt.
struct AWSRoleCredentials: Codable, Equatable {
    var accessKeyId: String
    var secretAccessKey: String
    var sessionToken: String
    var expiration: Double

    init(accessKeyId: String, secretAccessKey: String, sessionToken: String, expiration: Double) {
        self.accessKeyId = accessKeyId; self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken; self.expiration = expiration
    }
    private enum CodingKeys: String, CodingKey {
        case version = "Version", accessKeyId = "AccessKeyId", secretAccessKey = "SecretAccessKey"
        case sessionToken = "SessionToken", expiration = "Expiration"
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .version) == 1 else { throw PeerFailure("The AWS credential format is unsupported.") }
        accessKeyId = try values.decode(String.self, forKey: .accessKeyId)
        secretAccessKey = try values.decode(String.self, forKey: .secretAccessKey)
        sessionToken = try values.decode(String.self, forKey: .sessionToken)
        let text = try values.decode(String.self, forKey: .expiration)
        guard let date = Self.parseDate(text) else { throw PeerFailure("AWS did not provide a valid credential expiration.") }
        expiration = date.timeIntervalSince1970
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(1, forKey: .version)
        try values.encode(accessKeyId, forKey: .accessKeyId); try values.encode(secretAccessKey, forKey: .secretAccessKey)
        try values.encode(sessionToken, forKey: .sessionToken); try values.encode(Self.dateText(expiration), forKey: .expiration)
    }
    init(process: [String: Any], now: Double = Date().timeIntervalSince1970,
         allowExpired: Bool = false, syntheticOnly: Bool = false) throws {
        let allowed: Set<String> = ["Version", "AccessKeyId", "SecretAccessKey", "SessionToken", "Expiration", "AccountId"]
        guard Set(process.keys).isSubset(of: allowed), JSONSerialization.isValidJSONObject(process) else {
            throw PeerFailure("AWS returned an invalid credential response.")
        }
        if let account = process["AccountId"] {
            guard let account = account as? String, Self.isAccount(account) else { throw PeerFailure("AWS returned an invalid account identity.") }
        }
        let data = try JSONSerialization.data(withJSONObject: process)
        guard data.count <= 32_768 else { throw PeerFailure("The AWS credential response exceeded its limit.") }
        self = try JSONDecoder().decode(Self.self, from: data)
        try validate(now: now, allowExpired: allowExpired, syntheticOnly: syntheticOnly)
    }
    func processOutput() -> [String: Any] {
        ["Version": 1, "AccessKeyId": accessKeyId, "SecretAccessKey": secretAccessKey,
         "SessionToken": sessionToken, "Expiration": Self.dateText(expiration)]
    }
    func validate(now: Double, allowExpired: Bool = false, syntheticOnly: Bool = false) throws {
        guard expiration.isFinite, expiration > 0, expiration <= now + 43_500,
              allowExpired || expiration > now,
              (8...128).contains(accessKeyId.utf8.count),
              (16...4_096).contains(secretAccessKey.utf8.count),
              (16...24_000).contains(sessionToken.utf8.count),
              [accessKeyId, secretAccessKey, sessionToken].allSatisfy({ text in
                  text.unicodeScalars.allSatisfy { $0.value >= 33 && $0.value <= 126 }
              }),
              !syntheticOnly || [accessKeyId, secretAccessKey, sessionToken].allSatisfy({ $0.hasPrefix("tdb-test-") }) else {
            throw PeerFailure("AWS credentials are expired, malformed, or unavailable in this test environment.")
        }
    }
    fileprivate static func isAccount(_ value: String) -> Bool {
        value.utf8.count == 12 && value.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }
    fileprivate static func parseDate(_ text: String) -> Date? {
        guard text.utf8.count <= 64 else { return nil }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
    fileprivate static func dateText(_ timestamp: Double) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
    fileprivate var identityDigest: String {
        // Length-prefix fields: delimiters occurring in a secret cannot make
        // two different credentials share the same encoded input.
        var bytes = Data()
        for text in [accessKeyId, secretAccessKey, sessionToken] {
            var size = UInt64(text.utf8.count).bigEndian
            bytes.append(Data(bytes: &size, count: MemoryLayout<UInt64>.size)); bytes.append(contentsOf: text.utf8)
        }
        return PeerProtocol.fingerprint(bytes)
    }
    fileprivate func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

protocol SharedAWSSecrets {
    func read(_ id: String) throws -> Data
    func write(_ value: Data, id: String) throws
    func remove(_ id: String)
}

private struct SharedAWSKeychain: SharedAWSSecrets {
    private func query(_ id: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: "com.terminaldb.aws.shared",
         kSecAttrAccount: id, kSecAttrSynchronizable: false]
    }
    func read(_ id: String) throws -> Data {
        var q = query(id); q[kSecReturnData] = true; q[kSecMatchLimit] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &value) == errSecSuccess, let bytes = value as? Data else {
            throw PeerFailure("Unlock this Mac’s Keychain to use the shared AWS profile.")
        }
        return bytes
    }
    func write(_ value: Data, id: String) throws {
        var q = query(id); q[kSecValueData] = value; q[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        if status == errSecDuplicateItem {
            guard try read(id) == value else { throw PeerFailure("The AWS credential identity conflicted. Sign in again.") }
        } else if status != errSecSuccess { throw PeerFailure("macOS could not save the shared AWS credentials.") }
    }
    func remove(_ id: String) { SecItemDelete(query(id) as CFDictionary) }
}

private struct SharedAWSFixtureSecrets: SharedAWSSecrets {
    let root: URL
    func read(_ id: String) throws -> Data { try Data(contentsOf: root.appendingPathComponent(id)) }
    func write(_ value: Data, id: String) throws {
        let credentials = try JSONDecoder().decode(AWSRoleCredentials.self, from: value)
        try credentials.validate(now: Date().timeIntervalSince1970, allowExpired: true, syntheticOnly: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = root.appendingPathComponent(id)
        if let previous = try? Data(contentsOf: path), previous != value { throw PeerFailure("A synthetic AWS credential conflicted.") }
        try value.write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
    func remove(_ id: String) { try? FileManager.default.removeItem(at: root.appendingPathComponent(id)) }
}

struct SharedAWSRoleVersion: Codable, Equatable {
    var id: String
    var profile: AWSProfileDescriptor
    var principalARN: String
    var accountID: String
    var expiration: Double
    var credential: String
    var digest: String
    var identityDigest: String
}

struct SharedAWSSnapshot: Codable, Equatable {
    var revision: UInt64
    var sourceName: String
    var roles: [String: SharedAWSRoleVersion]
}

struct SharedAWSDocument: Codable {
    var version = 1
    var writer = UUID().uuidString
    var machine: String?
    var sources: [String: SharedAWSSnapshot] = [:]
    // Retain a bounded, expiring lower bound for a previously seen credential.
    // A later snapshot cannot lengthen the AWS expiration of those same keys.
    var expirations: [String: Double] = [:]
}

final class SharedAWSStore {
    static let maximumEntries = 128
    static let maximumSources = 128
    private static let maximumVersions = 512
    private static let maximumHistory = 2_048
    let root: URL
    let secrets: SharedAWSSecrets
    private let machine: String
    private let now: () -> Double
    private let syntheticOnly: Bool

    init(root: URL = PeerPaths.root, secrets: SharedAWSSecrets? = nil, machine: String? = nil,
         now: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.root = root; self.now = now
        var host = UUID().uuid; var timeout = timespec(tv_sec: 1, tv_nsec: 0)
        let identified = gethostuuid(&host, &timeout) == 0
        self.machine = machine ?? (identified ? PeerProtocol.fingerprint(Data(UUID(uuid: host).uuidString.utf8)) : "")
        let environment = ProcessInfo.processInfo.environment
        syntheticOnly = environment["TERMINALDB_PEER_QA"] == "1" && environment["TERMINALDB_PEER_EPHEMERAL_IDENTITY"] == "1"
        if let secrets { self.secrets = secrets }
        else if syntheticOnly { self.secrets = SharedAWSFixtureSecrets(root: root.appendingPathComponent("fixture-aws-credentials")) }
        else { self.secrets = SharedAWSKeychain() }
    }

    func load() throws -> SharedAWSDocument {
        let file = root.appendingPathComponent("shared-aws.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return SharedAWSDocument() }
        let bytes = try Data(contentsOf: file)
        guard bytes.count <= 1_000_000 else { throw PeerFailure("The shared AWS catalog exceeded its limit.") }
        let doc = try JSONDecoder().decode(SharedAWSDocument.self, from: bytes)
        try validate(doc)
        return doc
    }

    private func locked<T>(_ action: (inout SharedAWSDocument) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(root.appendingPathComponent("shared-aws.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw PeerFailure("The shared AWS catalog could not be opened.") }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw PeerFailure("The shared AWS catalog is busy.") }
        defer { flock(fd, LOCK_UN) }
        var doc = try load()
        if !machine.isEmpty {
            if let previous = doc.machine, previous != machine { doc.writer = UUID().uuidString }
            doc.machine = machine
        }
        let oldSecrets = Set(doc.sources.values.flatMap { $0.roles.values.map(\.credential) })
        doc.expirations = doc.expirations.filter { $0.value > now() }
        let result = try action(&doc)
        try validate(doc)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(doc)
        guard bytes.count <= 1_000_000 else { throw PeerFailure("The shared AWS catalog exceeded its limit.") }
        let file = root.appendingPathComponent("shared-aws.json")
        if (try? Data(contentsOf: file)) != bytes {
            try bytes.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        let retained = Set(doc.sources.values.flatMap { $0.roles.values.filter { $0.expiration > now() }.map(\.credential) })
        for id in oldSecrets.subtracting(retained) { secrets.remove(id) }
        return result
    }

    static func canonicalPrincipal(_ arn: String) throws -> (arn: String, account: String) {
        guard arn.utf8.count <= 2_048, arn.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }) else {
            throw PeerFailure("AWS did not return a valid principal identity.")
        }
        let parts = arn.split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 6, parts[0] == "arn", parts[1].hasPrefix("aws"),
              parts[1].utf8.allSatisfy({ ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 }),
              ["iam", "sts"].contains(parts[2]), parts[3].isEmpty,
              AWSRoleCredentials.isAccount(parts[4]), !parts[5].isEmpty else {
            throw PeerFailure("AWS did not return a valid principal identity.")
        }
        var resource = parts[5]
        if parts[2] == "sts", resource.hasPrefix("assumed-role/") {
            var segments = resource.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard segments.count >= 3, segments.allSatisfy({ !$0.isEmpty }) else { throw PeerFailure("AWS did not return a valid role identity.") }
            segments.removeLast(); segments[0] = "role"
            resource = segments.joined(separator: "/")
            return ("arn:\(parts[1]):iam::\(parts[4]):\(resource)", parts[4])
        }
        guard (parts[2] == "iam" && (resource == "root" || resource.hasPrefix("role/") || resource.hasPrefix("user/"))) ||
              (parts[2] == "sts" && resource.hasPrefix("federated-user/")) else {
            throw PeerFailure("AWS returned an unsupported principal identity.")
        }
        return (arn, parts[4])
    }
    static func identity(profile: AWSProfileDescriptor, principalARN: String) throws -> String {
        let principal = try canonicalPrincipal(principalARN)
        return PeerProtocol.fingerprint(Data((principal.account + "\n" + principal.arn + "\n" + profile.id).utf8))
    }
    private static func validHash(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }
    private func validate(_ role: SharedAWSRoleVersion) throws {
        try role.profile.validate()
        let principal = try Self.canonicalPrincipal(role.principalARN)
        guard role.principalARN == principal.arn, role.accountID == principal.account,
              role.profile.accountID.isEmpty || role.profile.accountID == principal.account,
              role.id == (try Self.identity(profile: role.profile, principalARN: role.principalARN)),
              UUID(uuidString: role.credential) != nil, Self.validHash(role.digest), Self.validHash(role.identityDigest),
              role.expiration.isFinite, role.expiration > 0, role.expiration <= now() + 43_500 else {
            throw PeerFailure("The shared AWS role description is invalid.")
        }
        if role.profile.kind == "sso" {
            let parts = principal.arn.split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
            let resource = parts[5].split(separator: "/").map(String.init)
            let prefix = "AWSReservedSSO_" + role.profile.roleName + "_"
            let name = resource.last ?? ""
            let suffix = name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : ""
            guard parts[2] == "iam", resource.first == "role", suffix.utf8.count == 16,
                  suffix.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) || ($0 >= 65 && $0 <= 70) }) else {
                throw PeerFailure("The shared AWS credentials describe a different role.")
            }
        } else {
            let expected = try Self.canonicalPrincipal(role.profile.loginSession)
            func roleIdentity(_ arn: String) -> String {
                var parts = arn.split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
                let resource = parts[5].split(separator: "/").map(String.init)
                // STS omits an IAM role's path; names are unique per account.
                if parts[2] == "iam", resource.first == "role", let name = resource.last { parts[5] = "role/" + name }
                return parts.joined(separator: ":")
            }
            guard expected.account == principal.account, roleIdentity(expected.arn) == roleIdentity(principal.arn) else {
                throw PeerFailure("The shared AWS credentials describe a different signed-in identity.")
            }
        }
    }
    private func validate(_ doc: SharedAWSDocument) throws {
        guard doc.version == 1, UUID(uuidString: doc.writer) != nil,
              doc.machine == nil || doc.machine!.utf8.count <= 128,
              doc.sources.count <= Self.maximumSources, doc.expirations.count <= Self.maximumHistory,
              Set(doc.sources.values.flatMap { $0.roles.keys }).count <= Self.maximumEntries,
              doc.sources.values.reduce(0, { $0 + $1.roles.count }) <= Self.maximumVersions,
              doc.expirations.allSatisfy({ Self.validHash($0.key) && $0.value.isFinite && $0.value > 0 && $0.value <= now() + 43_500 }) else {
            throw PeerFailure("The shared AWS catalog is invalid or full.")
        }
        var references: [String: SharedAWSRoleVersion] = [:]
        for (source, snapshot) in doc.sources {
            guard UUID(uuidString: source) != nil, snapshot.revision > 0, snapshot.revision <= 1_000_000_000,
                  !snapshot.sourceName.isEmpty, snapshot.sourceName.utf8.count <= 160,
                  !snapshot.sourceName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw PeerFailure("The shared AWS source description is invalid.")
            }
            for (id, role) in snapshot.roles {
                guard id == role.id else { throw PeerFailure("The shared AWS role identity is invalid.") }
                try validate(role)
                if let old = references[role.credential], old != role { throw PeerFailure("The shared AWS credential reference conflicted.") }
                references[role.credential] = role
            }
        }
    }
    private func nextRevision(_ snapshot: SharedAWSSnapshot?) throws -> UInt64 {
        let revision = snapshot?.revision ?? 0
        guard revision < 1_000_000_000 else { throw PeerFailure("The AWS source revision limit was reached.") }
        return revision + 1
    }
    private func remember(_ credentials: AWSRoleCredentials, in doc: inout SharedAWSDocument) throws {
        let digest = credentials.identityDigest
        if let previous = doc.expirations[digest], credentials.expiration > previous + 0.001 {
            throw PeerFailure("An AWS credential expiration was extended. Sign in again.")
        }
        if credentials.expiration > now() { doc.expirations[digest] = min(doc.expirations[digest] ?? credentials.expiration, credentials.expiration) }
        guard doc.expirations.count <= Self.maximumHistory else { throw PeerFailure("Too many AWS credential changes are pending.") }
    }

    @discardableResult func publish(profile: AWSProfileDescriptor, principalARN: String, credentials: AWSRoleCredentials,
                                    sourceName: String = Host.current().localizedName ?? "Mac") throws -> String {
        try profile.validate(); try credentials.validate(now: now(), syntheticOnly: syntheticOnly)
        let principal = try Self.canonicalPrincipal(principalARN)
        let id = try Self.identity(profile: profile, principalARN: principal.arn)
        let bytes = try credentials.encoded()
        return try locked { doc in
            try remember(credentials, in: &doc)
            let old = doc.sources[doc.writer]
            var roles = old?.roles ?? [:]
            let digest = PeerProtocol.fingerprint(bytes)
            if let role = roles[id], role.profile == profile, role.principalARN == principal.arn,
               role.digest == digest, old?.sourceName == sourceName {
                try secrets.write(bytes, id: role.credential)
                return id
            }
            let role = SharedAWSRoleVersion(id: id, profile: profile, principalARN: principal.arn,
                accountID: principal.account, expiration: credentials.expiration, credential: UUID().uuidString,
                digest: digest, identityDigest: credentials.identityDigest)
            try validate(role)
            // Recreated IAM Identity Center permission sets have a new role
            // ARN. A source's latest verified login replaces its old principal
            // for that profile instead of leaving a permanent conflict behind.
            roles = roles.filter { $0.value.profile.id != profile.id || $0.key == id }
            roles[id] = role
            doc.sources[doc.writer] = SharedAWSSnapshot(revision: try nextRevision(old), sourceName: sourceName, roles: roles)
            try validate(doc)
            try secrets.write(bytes, id: role.credential)
            return id
        }
    }
    func withdraw(_ id: String) throws {
        try locked { doc in
            guard let old = doc.sources[doc.writer] else { return }
            var roles = old.roles
            roles = roles.filter { $0.key != id && $0.value.profile.id != id }
            guard roles != old.roles else { return }
            doc.sources[doc.writer] = SharedAWSSnapshot(revision: try nextRevision(old), sourceName: old.sourceName, roles: roles)
        }
    }
    func withdrawAll() throws {
        try locked { doc in
            guard let old = doc.sources[doc.writer], !old.roles.isEmpty else { return }
            doc.sources[doc.writer] = SharedAWSSnapshot(revision: try nextRevision(old), sourceName: old.sourceName, roles: [:])
        }
    }
    private func credential(_ role: SharedAWSRoleVersion) throws -> AWSRoleCredentials {
        guard role.expiration > now() else { throw PeerFailure("The shared AWS credentials have expired. Sign in on an approved Mac.") }
        let bytes = try secrets.read(role.credential)
        guard bytes.count <= 32_768, PeerProtocol.fingerprint(bytes) == role.digest else { throw PeerFailure("The AWS credentials are waiting for sync.") }
        let value = try JSONDecoder().decode(AWSRoleCredentials.self, from: bytes)
        try value.validate(now: now(), syntheticOnly: syntheticOnly)
        guard abs(value.expiration - role.expiration) < 0.001, value.identityDigest == role.identityDigest else {
            throw PeerFailure("The shared AWS credential description conflicted.")
        }
        return value
    }
    private func ranked(_ doc: SharedAWSDocument, matching id: String) -> [(source: String, snapshot: SharedAWSSnapshot, role: SharedAWSRoleVersion)] {
        doc.sources.flatMap { source, snapshot in
            snapshot.roles.values.filter { $0.id == id || $0.profile.id == id }.map { (source, snapshot, $0) }
        }.sorted { a, b in
            if a.role.expiration != b.role.expiration { return a.role.expiration > b.role.expiration }
            if a.source != b.source { return a.source < b.source }
            return a.role.credential < b.role.credential
        }
    }
    func credentials(for id: String) throws -> AWSRoleCredentials {
        let matches = ranked(try load(), matching: id)
        guard Set(matches.filter { $0.role.expiration > now() }.map { $0.role.id }).count <= 1 else {
            throw PeerFailure("This AWS profile has conflicting identities. Choose its account and role again.")
        }
        for item in matches { if let value = try? credential(item.role) { return value } }
        throw PeerFailure("No usable credentials are available for this AWS profile. Connect to an approved Mac or sign in here.")
    }
    func credentials(forProfile id: String) throws -> AWSRoleCredentials { try credentials(for: id) }
    func profiles() throws -> [AWSProfileDescriptor] {
        let doc = try load()
        let ids = Set(doc.sources.values.flatMap { $0.roles.values.map { $0.profile.id } })
        return ids.sorted().compactMap { ranked(doc, matching: $0).first?.role.profile }
    }
    func catalog() throws -> [[String: Any]] {
        let doc = try load()
        let ids = Set(doc.sources.values.flatMap { $0.roles.values.map { $0.profile.id } })
        return try ids.sorted().compactMap { id in
            let matches = ranked(doc, matching: id)
            guard let first = matches.first else { return nil }
            let ambiguous = Set(matches.filter { $0.role.expiration > now() }.map { $0.role.id }).count > 1
            let usable = ambiguous ? nil : matches.first { (try? credential($0.role)) != nil }
            let selected = usable ?? first
            let profileData = try JSONEncoder().encode(selected.role.profile)
            let descriptor = try JSONSerialization.jsonObject(with: profileData) as! [String: Any]
            let sourceNames = Array(Set(matches.map { $0.snapshot.sourceName })).sorted()
            let status = ambiguous ? "Choose Account Again" : usable != nil ? "Ready" : selected.role.expiration <= now() ? "Expired" : "Waiting for Sync"
            return ["id": id, "profileId": id, "roleId": selected.role.id, "descriptor": descriptor,
                    "sourceName": selected.snapshot.sourceName, "sourceNames": sourceNames,
                    "expires": selected.role.expiration, "local": matches.contains { $0.source == doc.writer },
                    "available": usable != nil, "status": status,
                    "accountID": selected.role.accountID, "principalARN": selected.role.principalARN]
        }
    }

    func exportBundle() throws -> [String: Any] {
        try locked { doc in
            var values: [String: Any] = [:]
            for source in doc.sources.values { for role in source.roles.values {
                if let value = try? credential(role) { values[role.credential] = value.processOutput() }
            } }
            let data = try JSONEncoder().encode(doc.sources)
            let sources = try JSONSerialization.jsonObject(with: data)
            let result: [String: Any] = ["schema": 1, "sources": sources, "credentials": values]
            guard try JSONSerialization.data(withJSONObject: result).count <= 900_000 else { throw PeerFailure("The AWS sync transfer exceeded its limit.") }
            return result
        }
    }
    func digest() throws -> String {
        try locked { doc in
            // Missing Keychain copies must change the digest even when their
            // metadata survived, otherwise an equal snapshot could never repair.
            let available = doc.sources.values.flatMap { $0.roles.values }.compactMap { role -> String? in
                (try? credential(role)) != nil ? role.credential : nil
            }.sorted()
            let sourceData = try JSONEncoder().encode(doc.sources)
            let sources = try JSONSerialization.jsonObject(with: sourceData)
            let data = try JSONSerialization.data(withJSONObject: ["sources": sources, "available": available], options: [.sortedKeys])
            return PeerProtocol.fingerprint(data)
        }
    }
    func importBundle(_ bundle: [String: Any]) throws {
        guard Set(bundle.keys) == Set(["schema", "sources", "credentials"]),
              let schema = bundle["schema"],
              let schemaBytes = try? JSONSerialization.data(withJSONObject: [schema]),
              (try? JSONDecoder().decode([Int].self, from: schemaBytes)) == [1],
              let sourceObjects = bundle["sources"] as? [String: Any], let credentialObjects = bundle["credentials"] as? [String: Any],
              sourceObjects.count <= Self.maximumSources, credentialObjects.count <= Self.maximumVersions,
              JSONSerialization.isValidJSONObject(bundle),
              try JSONSerialization.data(withJSONObject: bundle).count <= 900_000 else {
            throw PeerFailure("The AWS sync transfer is invalid or too large.")
        }
        let sources = try JSONDecoder().decode([String: SharedAWSSnapshot].self,
            from: JSONSerialization.data(withJSONObject: sourceObjects))
        var incoming = SharedAWSDocument(); incoming.sources = sources
        try validate(incoming)
        var supplied: [String: (value: AWSRoleCredentials, bytes: Data)] = [:]
        let references = sources.values.flatMap { $0.roles.values }
        for (id, object) in credentialObjects {
            guard UUID(uuidString: id) != nil, let process = object as? [String: Any],
                  let role = references.first(where: { $0.credential == id }) else { throw PeerFailure("The AWS sync credential reference is invalid.") }
            let value = try AWSRoleCredentials(process: process, now: now(), allowExpired: true, syntheticOnly: syntheticOnly)
            let canonical = try value.encoded()
            guard role.digest == PeerProtocol.fingerprint(canonical), role.identityDigest == value.identityDigest,
                  abs(role.expiration - value.expiration) < 0.001 else { throw PeerFailure("The AWS sync credential description conflicted.") }
            supplied[id] = (value, canonical)
        }
        try locked { doc in
            var proposed = doc
            for (source, snapshot) in sources {
                if let old = proposed.sources[source] {
                    if snapshot.revision < old.revision { continue }
                    if snapshot.revision == old.revision {
                        guard snapshot == old else { throw PeerFailure("Conflicting AWS source revisions were rejected.") }
                    } else {
                        guard source != doc.writer else { throw PeerFailure("A remote AWS snapshot cannot replace this Mac’s source.") }
                        proposed.sources[source] = snapshot
                    }
                } else { proposed.sources[source] = snapshot }
            }
            var writes: [(String, Data)] = []
            for source in proposed.sources.values { for role in source.roles.values {
                if let payload = supplied[role.credential] {
                    try remember(payload.value, in: &proposed)
                    if payload.value.expiration > now() { writes.append((role.credential, payload.bytes)) }
                } else if let previous = proposed.expirations[role.identityDigest], role.expiration > previous + 0.001 {
                    throw PeerFailure("An AWS credential expiration was extended. Sign in again.")
                }
            } }
            try validate(proposed)
            // Validate the entire transfer before making any Keychain writes.
            // Unreferenced writes on an interrupted metadata commit are safe.
            for (id, bytes) in writes { try secrets.write(bytes, id: id) }
            doc = proposed
        }
    }
}
