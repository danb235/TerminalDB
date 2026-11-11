import Foundation
import CryptoKit
import Darwin

// Authentication metadata only. OIDC registrations, login caches and AWS keys
// never belong in a descriptor or its shared profile configuration.
struct AWSProfileDescriptor: Codable, Equatable {
    var id: String
    var name: String
    var kind: String
    var region: String
    var ssoStartURL: String
    var ssoRegion: String
    var accountID: String
    var roleName: String
    var loginSession: String
    var ssoSessionName: String

    init(id: String? = nil, name: String, kind: String, region: String = "", ssoStartURL: String = "", ssoRegion: String = "", accountID: String = "", roleName: String = "", loginSession: String = "", ssoSessionName: String = "") {
        self.name = name; self.kind = kind; self.region = region
        self.ssoStartURL = ssoStartURL; self.ssoRegion = ssoRegion
        self.accountID = accountID.isEmpty && kind == "login" ? (loginSession.split(separator: ":", omittingEmptySubsequences: false).dropFirst(4).first.map(String.init) ?? "") : accountID
        self.roleName = roleName
        self.loginSession = loginSession; self.ssoSessionName = ssoSessionName
        self.id = id ?? ""
        if id == nil { self.id = identity }
    }
    private var identity: String {
        // Length-prefixed canonical JSON avoids delimiter ambiguities. A profile
        // alias, output region or locally named SSO session is not an identity.
        let fields = kind == "sso" ? ["sso", ssoStartURL, ssoRegion, accountID, roleName] : ["login", loginSession]
        let bytes = (try? JSONSerialization.data(withJSONObject: fields)) ?? Data()
        return Self.hash(bytes)
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func validName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value == value.trimmingCharacters(in: .whitespacesAndNewlines) &&
            !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || "[]".unicodeScalars.contains($0) }
    }
    func validate() throws {
        let fields = [name, kind, region, ssoStartURL, ssoRegion, accountID, roleName, loginSession, ssoSessionName]
        guard Self.validName(name), fields.allSatisfy({ $0.utf8.count <= 2048 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }),
              id.count == 64, id.allSatisfy(\.isHexDigit), id == identity,
              region.isEmpty || region.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)+-[0-9]+$"#, options: .regularExpression) != nil else {
            throw PeerFailure("The AWS profile description is invalid.")
        }
        if kind == "sso" {
            guard let url = URLComponents(string: ssoStartURL), url.scheme == "https", url.host != nil,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  ssoRegion.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)+-[0-9]+$"#, options: .regularExpression) != nil,
                  accountID.count == 12, accountID.utf8.allSatisfy({ (48...57).contains($0) }),
                  !roleName.isEmpty, roleName.utf8.count <= 256,
                  loginSession.isEmpty, ssoSessionName.isEmpty || Self.validName(ssoSessionName) else {
                throw PeerFailure("The AWS SSO profile is incomplete.")
            }
        } else if kind == "login" {
            guard loginSession.range(of: #"^arn:[a-z0-9-]+:(?:iam|sts)::[0-9]{12}:.+$"#, options: .regularExpression) != nil,
                  ssoStartURL.isEmpty, ssoRegion.isEmpty, roleName.isEmpty, ssoSessionName.isEmpty,
                  accountID == loginSession.split(separator: ":", omittingEmptySubsequences: false).dropFirst(4).first.map(String.init) else {
                throw PeerFailure("The AWS login profile is incomplete.")
            }
        } else { throw PeerFailure("Only AWS SSO and browser-login profiles can be shared.") }
    }
}

// Metadata about one SSO session's AWS CLI token cache. No token value
// ever leaves AWSProfileConfiguration.
struct AWSSSOSessionCacheStatus: Equatable {
    var present = false
    var readable = false
    var hasRefreshToken = false
    var accessTokenCurrent = false
    var modifiedAt: Double?
}

struct AWSProfileInstallation: Codable, Equatable {
    var descriptor: AWSProfileDescriptor
    var targetName: String
    var configurationPath: String
    var backingConfigurationPath: String
    var backupPath: String
    var originalProfile: String?
    var installedProfileHash: String
    var appendedSeparator: String? = nil
}

// Parse only the small, documented authentication subset, while retaining every
// unrelated byte for explicit profile edits. No credentials/config are watched
// or changed merely by constructing this object or discovering profiles.
final class AWSProfileConfiguration {
    let configURL: URL
    let root: URL
    private let ssoCacheURL: URL
    private static let maximumBytes = 1_048_576
    private static let unsafeAuthentication = Set(["aws_access_key_id", "aws_secret_access_key", "aws_session_token", "aws_security_token", "credential_process", "credential_source", "source_profile", "role_arn", "web_identity_token_file"])
    private static let sourceKeys = Set(["sso_session", "sso_start_url", "sso_region", "sso_account_id", "sso_role_name", "login_session"])

    init(configURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".aws/config"), root: URL = PeerPaths.root.appendingPathComponent("aws-profiles"), ssoCacheURL: URL? = nil) {
        self.configURL = configURL; self.root = root
        self.ssoCacheURL = ssoCacheURL ?? (SharedAccountCodeIdentity.fixture ? root.deletingLastPathComponent() : FileManager.default.homeDirectoryForCurrentUser).appendingPathComponent(".aws/sso/cache")
    }

    func discover() throws -> [AWSProfileDescriptor] {
        let document = try INI(data: read(configURL, missing: true) ?? Data())
        var result: [AWSProfileDescriptor] = []
        for section in document.sections {
            guard let name = section.profileName, let descriptor = try descriptor(name: name, fields: section.fields, document: document) else { continue }
            result.append(descriptor)
        }
        for installation in try installations() where installation.originalProfile != nil && !result.contains(where: { $0.id == installation.descriptor.id && $0.name == installation.descriptor.name }) {
            result.append(installation.descriptor)
        }
        guard result.count <= 128 else { throw PeerFailure("Too many AWS profiles are configured.") }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func configuredNames() throws -> [String] {
        let document = try INI(data: read(configURL, missing: true) ?? Data())
        let names = document.sections.compactMap(\.profileName)
        guard names.count <= 1024 else { throw PeerFailure("Too many AWS profile names are configured.") }
        return Array(Set(names)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // Creates a private source profile even on a receiving Mac. Only supported
    // auth metadata is emitted; endpoint/plugin/process settings never enter it.
    @discardableResult func prepareBackingConfig(_ profile: AWSProfileDescriptor) throws -> URL {
        try profile.validate(); try directory(root, create: true, privateMode: true)
        var lines = [profile.name == "default" ? "[default]" : "[profile \(profile.name)]"]
        if !profile.region.isEmpty { lines.append("region = \(profile.region)") }
        if profile.kind == "login" { lines.append("login_session = \(profile.loginSession)") }
        else {
            lines += ["sso_account_id = \(profile.accountID)", "sso_role_name = \(profile.roleName)"]
            if let session = try resolvedSSOSessionName(for: profile) {
                lines += ["sso_session = \(session)", "", "[sso-session \(session)]", "sso_start_url = \(profile.ssoStartURL)", "sso_region = \(profile.ssoRegion)", "sso_registration_scopes = sso:account:access"]
            } else {
                lines += ["sso_start_url = \(profile.ssoStartURL)", "sso_region = \(profile.ssoRegion)"]
            }
        }
        let file = backingConfiguration(for: profile)
        try atomicWrite(Data((lines.joined(separator: "\n") + "\n").utf8), to: file, mode: 0o600)
        return file
    }

    func backingConfiguration(for profile: AWSProfileDescriptor) -> URL {
        let alias = (try? JSONSerialization.data(withJSONObject: [profile.name, profile.ssoSessionName])) ?? Data()
        return root.appendingPathComponent(profile.id + "-" + AWSProfileDescriptor.hash(alias).prefix(24) + ".config")
    }
    func loginArguments(for profile: AWSProfileDescriptor) throws -> [String] {
        if let session = try resolvedSSOSessionName(for: profile) {
            return ["sso", "login", "--sso-session", session]
        }
        return (profile.kind == "sso" ? ["sso", "login"] : ["login"]) + ["--profile", profile.name]
    }

    func resolvedSSOSessionName(for profile: AWSProfileDescriptor) throws -> String? {
        try profile.validate()
        guard profile.kind == "sso" else { return nil }
        let document = try INI(data: read(configURL, missing: true) ?? Data())
        func matches(_ section: INI.Section) -> Bool {
            section.fields["sso_start_url"] == profile.ssoStartURL && section.fields["sso_region"] == profile.ssoRegion
        }
        // An explicit native alias remains authoritative when it exists.
        if let section = document.profile(profile.name),
           let native = try descriptor(name: profile.name, fields: section.fields, document: document), native.id == profile.id {
            return native.ssoSessionName.isEmpty ? nil : native.ssoSessionName
        }
        // Preserve the local session of a deliberately replaced native alias.
        // Do not borrow another local user's session just because portals match.
        for installation in try installations() where installation.descriptor.id == profile.id && (installation.targetName == profile.name || installation.descriptor.name == profile.name) {
            if let original = installation.originalProfile,
               let section = try INI(data: Data(original.utf8)).profile(installation.targetName),
               let native = try descriptor(name: installation.targetName, fields: section.fields, document: document), native.id == profile.id {
                return native.ssoSessionName.isEmpty ? nil : native.ssoSessionName
            }
        }
        guard !profile.ssoSessionName.isEmpty else { return nil }
        if let local = document.sections.first(where: { $0.name == "sso-session " + profile.ssoSessionName }), matches(local) {
            return profile.ssoSessionName
        }
        // All roles imported from one named session share the same local login.
        // Keep different named sessions separate even when their portals match.
        let identity = try JSONSerialization.data(withJSONObject: [profile.ssoStartURL, profile.ssoRegion, profile.ssoSessionName])
        let session = "terminaldb-sso-" + AWSProfileDescriptor.hash(identity)
        if let local = document.sections.first(where: { $0.name == "sso-session " + session }), !matches(local) {
            throw PeerFailure("The private AWS session name already belongs to another portal. Review the AWS configuration before signing in.")
        }
        return session
    }

    // Cached SSO token freshness is independent of longer-lived account/role
    // credentials. The official AWS CLI owns authentication and token refresh.
    // Only status metadata leaves this bounded, local-only read.
    func authenticationStatus(for profile: AWSProfileDescriptor, now: Date = Date()) -> [String: Any] {
        guard profile.kind == "sso" else { return ["state": "notApplicable"] }
        var result: [String: Any] = ["state": "unknown"]
        do {
            let session = try resolvedSSOSessionName(for: profile)
            if let session { result["sessionName"] = session }
            let filename = Self.ssoCacheFilename(session: session, startURL: profile.ssoStartURL)
            guard var bytes = try read(ssoCacheURL.appendingPathComponent(filename), missing: true, maximumBytes: 65_536) else {
                result["state"] = "missing"; return result
            }
            defer { bytes.resetBytes(in: 0..<bytes.count) }
            let metadata = try JSONDecoder().decode(SSOCacheMetadata.self, from: bytes)
            guard metadata.hasAccessToken, metadata.startURL == profile.ssoStartURL, metadata.region == profile.ssoRegion,
                  let expiry = Self.ssoDate(metadata.expiresAt), expiry.timeIntervalSince1970.isFinite else { return result }
            result["expiresAt"] = expiry.timeIntervalSince1970
            result["state"] = expiry > now ? "current" : "expired"
        } catch { /* Unreadable or unsafe cache is unknown, never signed in. */ }
        return result
    }

    // AWS CLI names a session's token cache by the SHA-1 of the sso-session
    // name, or of the start URL for legacy profiles without a named session.
    private static func ssoCacheFilename(session: String?, startURL: String) -> String {
        Insecure.SHA1.hash(data: Data((session ?? startURL).utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
    }

    // The token cache file that belongs to this profile's SSO session.
    func ssoSessionCacheFile(for profile: AWSProfileDescriptor) -> URL? {
        guard profile.kind == "sso" else { return nil }
        let session: String?
        do { session = try resolvedSSOSessionName(for: profile) } catch { return nil }
        return ssoCacheURL.appendingPathComponent(Self.ssoCacheFilename(session: session, startURL: profile.ssoStartURL))
    }

    // Presence and freshness flags only. Token values are decoded into
    // booleans and the raw bytes are wiped before this returns.
    func ssoSessionCacheStatus(for profile: AWSProfileDescriptor, now: Date = Date()) -> AWSSSOSessionCacheStatus {
        var status = AWSSSOSessionCacheStatus()
        guard let file = ssoSessionCacheFile(for: profile) else { return status }
        do {
            guard var bytes = try read(file, missing: true, maximumBytes: 65_536) else { return status }
            defer { bytes.resetBytes(in: 0..<bytes.count) }
            status.present = true
            var st = stat()
            if lstat(file.path, &st) == 0 {
                status.modifiedAt = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1_000_000_000
            }
            let metadata = try JSONDecoder().decode(SSOCacheMetadata.self, from: bytes)
            guard metadata.startURL == profile.ssoStartURL, metadata.region == profile.ssoRegion else { return status }
            status.readable = true
            status.hasRefreshToken = metadata.hasRefreshToken
            if metadata.hasAccessToken, let expiry = Self.ssoDate(metadata.expiresAt), expiry.timeIntervalSince1970.isFinite {
                status.accessTokenCurrent = expiry > now
            }
        } catch { /* An unreadable or unsafe cache reports only its presence. */ }
        return status
    }

    // Copies exactly this session's token cache into a private directory for
    // a sandboxed AWS CLI run. Returns false when the session has no cache.
    func copySSOSessionCache(for profile: AWSProfileDescriptor, into directory: URL) throws -> Bool {
        guard let file = ssoSessionCacheFile(for: profile) else { throw PeerFailure("Choose an AWS SSO profile.") }
        guard var bytes = try read(file, missing: true, maximumBytes: 65_536) else { return false }
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        let metadata = try JSONDecoder().decode(SSOCacheMetadata.self, from: bytes)
        guard metadata.startURL == profile.ssoStartURL, metadata.region == profile.ssoRegion else {
            throw PeerFailure("The AWS session cache belongs to another portal.")
        }
        try self.directory(directory, create: false, privateMode: true)
        try atomicWrite(bytes, to: directory.appendingPathComponent(file.lastPathComponent), mode: 0o600)
        return true
    }

    // Removes only this session's token cache. Other sessions' caches and
    // issued role credentials are never touched.
    func removeSSOSessionCache(for profile: AWSProfileDescriptor) throws {
        guard let file = ssoSessionCacheFile(for: profile) else { throw PeerFailure("Choose an AWS SSO profile.") }
        guard FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path) else { return }
        let dir = try directoryFD(file.deletingLastPathComponent()); defer { Darwin.close(dir) }
        var st = stat()
        guard fstatat(dir, file.lastPathComponent, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw PeerFailure("The AWS session cache could not be inspected safely.")
        }
        guard (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid() else { throw PeerFailure("The AWS session cache is not a regular file.") }
        guard unlinkat(dir, file.lastPathComponent, 0) == 0 || errno == ENOENT else { throw PeerFailure("The AWS session cache could not be removed.") }
    }

    private struct SSOCacheMetadata: Decodable {
        var startURL: String
        var region: String
        var expiresAt: String
        var hasAccessToken: Bool
        var hasRefreshToken: Bool
        enum CodingKeys: String, CodingKey { case startUrl, region, expiresAt, accessToken, refreshToken }
        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            startURL = try fields.decode(String.self, forKey: .startUrl)
            region = try fields.decode(String.self, forKey: .region)
            expiresAt = try fields.decode(String.self, forKey: .expiresAt)
            hasAccessToken = !(try fields.decodeIfPresent(String.self, forKey: .accessToken) ?? "").isEmpty
            hasRefreshToken = !(try fields.decodeIfPresent(String.self, forKey: .refreshToken) ?? "").isEmpty
        }
    }
    private static func ssoDate(_ text: String) -> Date? {
        let normalized = text.hasSuffix("UTC") ? String(text.dropLast(3)) + "Z" : text
        let formatter = ISO8601DateFormatter()
        if let value = formatter.date(from: normalized) { return value }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: normalized)
    }

    func installations() throws -> [AWSProfileInstallation] {
        let path = root.appendingPathComponent("installations")
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        try directory(path, create: false, privateMode: true)
        let files = try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        guard files.count <= 128 else { throw PeerFailure("Too many managed AWS profiles are configured.") }
        return try files.map {
            guard let bytes = try read($0, missing: false) else { throw PeerFailure("The AWS profile record is unavailable.") }
            let record = try JSONDecoder().decode(AWSProfileInstallation.self, from: bytes)
            try record.descriptor.validate()
            guard AWSProfileDescriptor.validName(record.targetName), record.configurationPath == configURL.path,
                  record.backingConfigurationPath == backingConfiguration(for: record.descriptor).path,
                  record.installedProfileHash.count == 64 else { throw PeerFailure("The managed AWS profile record is invalid.") }
            return record
        }
    }

    // Only this explicit call changes ~/.aws/config. A matching source profile
    // requires approval; a different existing target is never silently replaced.
    @discardableResult func install(_ profile: AWSProfileDescriptor, targetName: String, launcherPath: String, allowReplacingSource: Bool = false) throws -> AWSProfileInstallation {
        try profile.validate()
        guard AWSProfileDescriptor.validName(targetName), launcherPath.hasPrefix("/"), launcherPath.utf8.count <= 4096,
              !launcherPath.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw PeerFailure("Choose a valid AWS profile name and installed credential helper.") }
        return try locked {
            let bytes = try self.read(self.configURL, missing: true) ?? Data()
            let document = try INI(data: bytes)
            let section = document.profile(targetName)
            let existing = try self.installations().first { $0.targetName == targetName }
            if let existing {
                guard existing.descriptor.id == profile.id,
                      section.map({ AWSProfileDescriptor.hash(Data($0.raw.utf8)) }) == existing.installedProfileHash else {
                    throw PeerFailure("That AWS profile has changed. Restore or choose another profile name.")
                }
                return existing
            }
            if let section {
                guard allowReplacingSource,
                      let source = try self.descriptor(name: targetName, fields: section.fields, document: document), source.id == profile.id else {
                    throw PeerFailure("That AWS profile name already exists. Choose another name, or explicitly replace its matching sign-in profile.")
                }
            }
            let backing = try self.prepareBackingConfig(profile)
            let newline = document.newline
            // credential_process has its own argument parser, not a shell. Quote
            // every argument using double-quote/backslash escaping for that parser.
            let command = [launcherPath, "--aws-credentials", profile.id].map(Self.quoteArgument).joined(separator: " ")
            var profileLines = [targetName == "default" ? "[default]" : "[profile \(targetName)]", "# Managed by TerminalDB. Restore in AWS Access to use the original sign-in."]
            if let section {
                for line in section.lines.dropFirst() {
                    if let key = INI.keyValue(line)?.0, Self.sourceKeys.contains(key) { continue }
                    profileLines.append(INI.content(line))
                }
            } else if !profile.region.isEmpty { profileLines.append("region = \(profile.region)") }
            profileLines.append("credential_process = \(command)")
            let replacement = profileLines.joined(separator: newline) + newline
            let updated = document.replacing(section, with: replacement)
            let backupDirectory = self.root.appendingPathComponent("backups")
            try self.directory(backupDirectory, create: true, privateMode: true)
            let backup = backupDirectory.appendingPathComponent(UUID().uuidString + ".config")
            try self.atomicWrite(bytes, to: backup, mode: 0o600)
            var record = AWSProfileInstallation(descriptor: profile, targetName: targetName, configurationPath: self.configURL.path, backingConfigurationPath: backing.path, backupPath: backup.path, originalProfile: section?.raw, installedProfileHash: AWSProfileDescriptor.hash(Data(replacement.utf8)))
            if section == nil && !bytes.isEmpty && bytes.last != 10 { record.appendedSeparator = newline }
            let records = self.root.appendingPathComponent("installations")
            try self.directory(records, create: true, privateMode: true)
            let recordURL = self.installationURL(targetName)
            // Persist the recovery record before editing the public config. If
            // interrupted, restore refuses to overwrite an unexpected profile.
            try self.atomicWrite(try JSONEncoder().encode(record), to: recordURL, mode: 0o600)
            do {
                guard try self.read(self.configURL, missing: true) ?? Data() == bytes else { throw PeerFailure("The AWS configuration changed while preparing this profile. Try again; your edits were kept.") }
                try self.atomicWrite(updated, to: self.configURL, mode: self.fileMode(self.configURL))
            }
            catch { try? FileManager.default.removeItem(at: recordURL); throw error }
            return record
        }
    }

    func restore(_ installation: AWSProfileInstallation) throws {
        try installation.descriptor.validate()
        guard installation.configurationPath == configURL.path, AWSProfileDescriptor.validName(installation.targetName) else { throw PeerFailure("The AWS profile recovery record belongs to another configuration.") }
        try locked {
            guard let stored = try self.installations().first(where: { $0.targetName == installation.targetName }), stored == installation else { throw PeerFailure("The AWS profile recovery record changed. Review its backup before continuing.") }
            let bytes = try self.read(self.configURL, missing: false) ?? Data()
            let document = try INI(data: bytes)
            guard let current = document.profile(installation.targetName), AWSProfileDescriptor.hash(Data(current.raw.utf8)) == installation.installedProfileHash else {
                throw PeerFailure("That AWS profile was edited outside TerminalDB. Your changes were kept; restore it manually from the private backup.")
            }
            guard try self.read(self.configURL, missing: false) == bytes else { throw PeerFailure("The AWS configuration changed during restoration. Your edits were kept.") }
            try self.atomicWrite(document.replacing(current, with: installation.originalProfile ?? "", removingAppendedSeparator: installation.appendedSeparator), to: self.configURL, mode: self.fileMode(self.configURL))
            try FileManager.default.removeItem(at: self.installationURL(installation.targetName))
        }
    }

    private func descriptor(name: String, fields: [String: String], document: INI) throws -> AWSProfileDescriptor? {
        guard !Self.unsafeAuthentication.contains(where: { fields[$0] != nil }) else { return nil }
        let profile: AWSProfileDescriptor
        if let login = fields["login_session"] {
            guard !Self.sourceKeys.subtracting(["login_session"]).contains(where: { fields[$0] != nil }) else { return nil }
            let account = login.split(separator: ":", omittingEmptySubsequences: false).dropFirst(4).first.map(String.init) ?? ""
            profile = .init(name: name, kind: "login", region: fields["region"] ?? "", accountID: account, loginSession: login)
        } else if fields["sso_session"] != nil || fields["sso_start_url"] != nil {
            let sessionName = fields["sso_session"] ?? ""
            var auth = fields
            if !sessionName.isEmpty {
                guard AWSProfileDescriptor.validName(sessionName), let session = document.sections.first(where: { $0.name == "sso-session " + sessionName }),
                      !Self.unsafeAuthentication.contains(where: { session.fields[$0] != nil }) else { return nil }
                auth["sso_start_url"] = session.fields["sso_start_url"]; auth["sso_region"] = session.fields["sso_region"]
            }
            profile = .init(name: name, kind: "sso", region: fields["region"] ?? "", ssoStartURL: auth["sso_start_url"] ?? "", ssoRegion: auth["sso_region"] ?? "", accountID: fields["sso_account_id"] ?? "", roleName: fields["sso_role_name"] ?? "", ssoSessionName: sessionName)
        } else { return nil }
        do { try profile.validate(); return profile } catch { return nil }
    }

    private func installationURL(_ name: String) -> URL { root.appendingPathComponent("installations/" + AWSProfileDescriptor.hash(Data(name.utf8)) + ".json") }
    private static func quoteArgument(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }

    private struct INI {
        struct Section {
            var name: String
            var range: Range<Int>
            var lines: [String]
            var fields: [String: String]
            var raw: String { lines.joined() }
            var profileName: String? { name == "default" ? "default" : (name.hasPrefix("profile ") ? String(name.dropFirst(8)) : nil) }
        }
        var lines: [String]
        var sections: [Section]
        var newline: String
        init(data: Data) throws {
            guard data.count <= AWSProfileConfiguration.maximumBytes, let text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw PeerFailure("The AWS configuration is too large or is not valid text.") }
            newline = text.contains("\r\n") ? "\r\n" : "\n"
            // String's Character splitting treats CRLF as one grapheme; split
            // scalar line delimiters so Windows-edited AWS configs work too.
            let parts = text.components(separatedBy: "\n")
            lines = parts.enumerated().map { index, value in value + (index < parts.count - 1 ? "\n" : "") }
            if lines.last == "" { lines.removeLast() }
            guard lines.count <= 20000 else { throw PeerFailure("The AWS configuration has too many lines.") }
            sections = []
            var starts: [(String, Int)] = []
            for (i, raw) in lines.enumerated() {
                let line = Self.content(raw).trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
                if line.hasPrefix("[") {
                    guard let close = line.firstIndex(of: "]"), close > line.index(after: line.startIndex) else { throw PeerFailure("The AWS configuration contains an invalid section.") }
                    let trailing = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
                    guard trailing.isEmpty || trailing.hasPrefix("#") || trailing.hasPrefix(";") else { throw PeerFailure("The AWS configuration contains an invalid section.") }
                    let name = String(line[line.index(after: line.startIndex)..<close])
                    guard !starts.contains(where: { $0.0 == name }), starts.count < 512 else { throw PeerFailure("The AWS configuration contains repeated or too many sections.") }
                    starts.append((name, i))
                } else if starts.isEmpty { throw PeerFailure("The AWS configuration contains settings outside a section.") }
            }
            for (index, item) in starts.enumerated() {
                let end = index + 1 < starts.count ? starts[index + 1].1 : lines.count
                var fields: [String: String] = [:]
                var previous: String?
                for raw in lines[(item.1 + 1)..<end] {
                    let trimmed = Self.content(raw).trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix(";") { continue }
                    if let (key, value) = Self.keyValue(raw) {
                        if fields[key] != nil && (AWSProfileConfiguration.sourceKeys.contains(key) || AWSProfileConfiguration.unsafeAuthentication.contains(key) || key == "region") { throw PeerFailure("The AWS configuration repeats an authentication setting.") }
                        fields[key] = value; previous = key
                    } else if let previous { fields[previous, default: ""] += "\n" + trimmed }
                    else { throw PeerFailure("The AWS configuration contains an invalid setting.") }
                }
                sections.append(Section(name: item.0, range: item.1..<end, lines: Array(lines[item.1..<end]), fields: fields))
            }
        }
        static func content(_ line: String) -> String { line.trimmingCharacters(in: .newlines) }
        static func keyValue(_ raw: String) -> (String, String)? {
            let line = content(raw).trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), !line.hasPrefix(";"), let split = line.firstIndex(where: { $0 == "=" || $0 == ":" }) else { return nil }
            let key = line[..<split].trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty, key.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_.-").contains($0) }) else { return nil }
            return (key, line[line.index(after: split)...].trimmingCharacters(in: .whitespaces))
        }
        func profile(_ name: String) -> Section? { sections.first { $0.profileName == name } }
        func replacing(_ section: Section?, with value: String, removingAppendedSeparator: String? = nil) -> Data {
            if let section {
                var before = lines[..<section.range.lowerBound].joined()
                let after = lines[section.range.upperBound...].joined()
                if value.isEmpty, after.isEmpty, let separator = removingAppendedSeparator,
                   ["\n", "\r\n"].contains(separator), before.utf8.suffix(separator.utf8.count).elementsEqual(separator.utf8) {
                    before = String(decoding: before.utf8.dropLast(separator.utf8.count), as: UTF8.self)
                }
                let separator = !value.isEmpty && !after.isEmpty && value.utf8.last != 10 ? newline : ""
                return Data((before + value + separator + after).utf8)
            }
            let text = lines.joined(); return Data((text + (text.isEmpty || text.utf8.last == 10 ? "" : newline) + value).utf8)
        }
    }

    private func directory(_ url: URL, create: Bool, privateMode: Bool = false) throws {
        if create && !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid(), st.st_mode & 0o022 == 0,
              !privateMode || st.st_mode & 0o077 == 0 else { throw PeerFailure("The AWS configuration directory must be owned by you and cannot be a symbolic link or writable by other users.") }
    }
    private func directoryFD(_ url: URL, create: Bool = false, privateMode: Bool = false) throws -> Int32 {
        try directory(url, create: create, privateMode: privateMode)
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw PeerFailure("The AWS configuration directory could not be opened safely.") }; return fd
    }
    private func read(_ url: URL, missing: Bool, maximumBytes: Int = AWSProfileConfiguration.maximumBytes) throws -> Data? {
        if missing && !FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) { return nil }
        let dir = try directoryFD(url.deletingLastPathComponent()); defer { Darwin.close(dir) }
        let fd = openat(dir, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT && missing { return nil }
        guard fd >= 0 else { throw PeerFailure("The AWS configuration could not be read safely. Symbolic links are not supported.") }
        defer { Darwin.close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(), st.st_nlink == 1, st.st_mode & 0o022 == 0, st.st_size <= maximumBytes else { throw PeerFailure("The AWS configuration is not a supported regular file.") }
        var result = Data(); var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw PeerFailure("The AWS configuration could not be read.") }
            if count == 0 { break }; result.append(contentsOf: buffer.prefix(count))
            guard result.count <= maximumBytes else { throw PeerFailure("The AWS configuration is too large.") }
        }
        return result
    }
    private func atomicWrite(_ data: Data, to url: URL, mode: mode_t) throws {
        guard data.count <= Self.maximumBytes else { throw PeerFailure("The AWS configuration is too large.") }
        let dir = try directoryFD(url.deletingLastPathComponent()); defer { Darwin.close(dir) }
        // Check the existing destination before replacing its directory entry.
        var st = stat()
        if fstatat(dir, url.lastPathComponent, &st, AT_SYMLINK_NOFOLLOW) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(), st.st_nlink == 1 else { throw PeerFailure("The AWS configuration cannot safely replace a link or another owner’s file.") }
        } else if errno != ENOENT { throw PeerFailure("The AWS configuration destination is unavailable.") }
        let temporary = ".terminaldb-" + UUID().uuidString
        let fd = openat(dir, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { throw PeerFailure("The AWS configuration could not be saved.") }
        var installed = false
        defer { Darwin.close(fd); if !installed { unlinkat(dir, temporary, 0) } }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw PeerFailure("The AWS configuration could not be saved.") }; offset += count
            }
        }
        guard fsync(fd) == 0, renameat(dir, temporary, dir, url.lastPathComponent) == 0 else { throw PeerFailure("The AWS configuration could not be installed atomically.") }
        installed = true; _ = fsync(dir)
    }
    private func fileMode(_ url: URL) -> mode_t {
        var st = stat()
        return lstat(url.path, &st) == 0 ? st.st_mode & 0o777 : 0o600
    }
    private func locked<T>(_ action: () throws -> T) throws -> T {
        let parent = configURL.deletingLastPathComponent()
        let dir = try directoryFD(parent, create: true); defer { Darwin.close(dir) }
        let fd = openat(dir, ".terminaldb-aws-config.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw PeerFailure("The AWS profile configuration is locked or unsafe.") }; defer { Darwin.close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(), st.st_nlink == 1,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw PeerFailure("The AWS profile configuration is busy. Try again.") }
        defer { flock(fd, LOCK_UN) }
        return try action()
    }
}
