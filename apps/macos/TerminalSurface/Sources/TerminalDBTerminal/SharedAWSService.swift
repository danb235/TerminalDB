import Foundation
import Darwin

// AWS CLI output is private protocol data. It is never forwarded to terminal
// renderers, UI errors, telemetry, command history or log streams.
private final class SharedAWSCommand {
    private let queue: DispatchQueue
    private let task = Process()
    private var reader: DispatchSourceRead?
    private var deadline: DispatchSourceTimer?
    private var output = Data()
    private var descriptor: Int32 = -1
    private var completed = false
    private var callback: ((Result<Data, Error>) -> Void)?
    private var pipe: Pipe?
    private let maximumOutput = 65_536

    init(queue: DispatchQueue) { self.queue = queue }

    func start(executable: URL, arguments: [String], environment: [String: String],
               timeout: Double, capture: Bool,
               completion: @escaping (Result<Data, Error>) -> Void) throws {
        callback = completion
        task.executableURL = executable; task.arguments = arguments
        task.environment = environment
        task.standardInput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        if capture {
            let channel = Pipe(); pipe = channel
            descriptor = channel.fileHandleForReading.fileDescriptor
            guard fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) == 0 else {
                throw PeerFailure("AWS credentials could not be read privately.")
            }
            task.standardOutput = channel
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.drain() }
            reader = source; source.resume()
        } else { task.standardOutput = FileHandle.nullDevice }
        task.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.drain()
                guard !self.completed else { return }
                if self.task.terminationStatus == 0 { self.finish(.success(self.output)) }
                else { self.finish(.failure(PeerFailure("AWS sign-in is unavailable. Sign in on this Mac, then try again."))) }
            }
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in
            self?.finish(.failure(PeerFailure("AWS did not finish in time. Check your connection and try again.")))
        }
        deadline = timer; timer.resume()
        do { try task.run() }
        catch { callback = nil; finish(.failure(PeerFailure("The installed AWS CLI could not start."))); throw PeerFailure("The installed AWS CLI could not start.") }
    }

    private func drain() {
        guard descriptor >= 0, !completed else { return }
        var bytes = [UInt8](repeating: 0, count: 4096)
        for _ in 0..<32 {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            guard count > 0 else { break }
            guard output.count + count <= maximumOutput else {
                finish(.failure(PeerFailure("AWS returned an invalid credential response."))); return
            }
            output.append(contentsOf: bytes.prefix(count))
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        guard !completed else { return }; completed = true
        deadline?.cancel(); deadline = nil
        reader?.cancel(); reader = nil; descriptor = -1
        try? pipe?.fileHandleForReading.close(); try? pipe?.fileHandleForWriting.close(); pipe = nil
        if task.isRunning {
            task.terminate()
            let process = task
            queue.asyncAfter(deadline: .now() + 2) {
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            }
        }
        output.resetBytes(in: 0..<output.count); output.removeAll()
        let completion = callback; callback = nil; completion?(result)
    }
    func cancel() { finish(.failure(PeerFailure("AWS sign-in cancelled."))) }
}

private enum SharedAWSCLI {
    static func executable(root: URL) throws -> URL {
        let files = FileManager.default
        if SharedAccountCodeIdentity.fixture {
            guard let candidate = ProcessInfo.processInfo.environment["TERMINALDB_AWS_QA_EXECUTABLE"] else {
                throw PeerFailure("The disposable AWS fixture is not configured.")
            }
            let url = URL(fileURLWithPath: candidate).resolvingSymlinksInPath()
            guard url.path.hasPrefix(root.resolvingSymlinksInPath().path + "/"), files.isExecutableFile(atPath: url.path) else {
                throw PeerFailure("Real AWS sign-ins cannot be used in a disposable test.")
            }
            return url
        }
        for candidate in ["/opt/homebrew/bin/aws", "/usr/local/bin/aws", "/usr/local/aws-cli/aws", "/usr/local/aws-cli/v2/current/bin/aws"] {
            let url = URL(fileURLWithPath: candidate).resolvingSymlinksInPath()
            guard files.isExecutableFile(atPath: url.path),
                  ["/opt/homebrew/Cellar/awscli/", "/usr/local/Cellar/awscli/", "/usr/local/aws-cli/"].contains(where: { url.path.hasPrefix($0) }) else { continue }
            var parent = url
            var safe = true
            while parent.path != "/" {
                var value = stat()
                if lstat(parent.path, &value) != 0 || (value.st_uid != 0 && value.st_uid != getuid()) || (value.st_mode & 0o002 != 0 || (value.st_mode & 0o020 != 0 && value.st_gid != getgrnam("admin")?.pointee.gr_gid)) {
                    safe = false; break
                }
                parent.deleteLastPathComponent()
            }
            if safe { return url }
        }
        throw PeerFailure("Install AWS CLI v2 from AWS or Homebrew on this Mac to sign in.")
    }

    static func environment(root: URL, config: URL, credentials: AWSRoleCredentials? = nil, region: String? = nil) throws -> [String: String] {
        let emptyCredentials = root.appendingPathComponent("aws-empty-credentials")
        if !FileManager.default.fileExists(atPath: emptyCredentials.path) {
            try Data().write(to: emptyCredentials, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: emptyCredentials.path)
        }
        var env = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                   "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                   "TMPDIR": NSTemporaryDirectory(), "TERM": "dumb", "NO_COLOR": "1",
                   "AWS_CONFIG_FILE": config.path,
                   "AWS_SHARED_CREDENTIALS_FILE": emptyCredentials.path,
                   "AWS_EC2_METADATA_DISABLED": "true", "AWS_CLI_AUTO_PROMPT": "off", "AWS_PAGER": ""]
        if SharedAccountCodeIdentity.fixture { env["HOME"] = root.path; env["TERMINALDB_PEER_QA"] = "1"; env["TERMINALDB_PEER_EPHEMERAL_IDENTITY"] = "1" }
        if let region, !region.isEmpty { env["AWS_DEFAULT_REGION"] = region }
        if let credentials {
            env["AWS_ACCESS_KEY_ID"] = credentials.accessKeyId
            env["AWS_SECRET_ACCESS_KEY"] = credentials.secretAccessKey
            env["AWS_SESSION_TOKEN"] = credentials.sessionToken
        }
        return env
    }
}

private enum SharedAWSPrincipal {
    static func verify(_ response: [String: Any], profile: AWSProfileDescriptor) throws -> String {
        guard let account = response["Account"] as? String, account.count == 12, account.allSatisfy(\.isNumber),
              let arn = response["Arn"] as? String, arn.utf8.count <= 2048,
              !arn.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              profile.accountID.isEmpty || account == profile.accountID else {
            throw PeerFailure("AWS returned credentials for a different account. Sign in again for the selected profile.")
        }
        let parts = arn.split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 6, parts[0] == "arn", parts[4] == account else {
            throw PeerFailure("AWS returned an invalid account identity.")
        }
        if profile.kind == "sso" {
            let resource = parts[5].split(separator: "/").map(String.init)
            guard parts[2] == "sts", resource.count == 3, resource[0] == "assumed-role" else {
                throw PeerFailure("AWS returned a different role. Sign in again for the selected profile.")
            }
            let prefix = "AWSReservedSSO_" + profile.roleName + "_"
            let role = resource[1]
            let suffix = role.hasPrefix(prefix) ? String(role.dropFirst(prefix.count)) : ""
            guard suffix.count == 16 && suffix.allSatisfy(\.isHexDigit) else {
                throw PeerFailure("AWS returned a different role. Sign in again for the selected profile.")
            }
        } else {
            guard canonical(arn) == canonical(profile.loginSession) else {
                throw PeerFailure("AWS returned a different signed-in identity. Sign in again for the selected profile.")
            }
        }
        return arn
    }
    private static func canonical(_ arn: String) -> String {
        var parts = arn.split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 6 else { return "" }
        let resource = parts[5].split(separator: "/").map(String.init)
        if parts[2] == "sts", resource.count == 3, resource[0] == "assumed-role" {
            parts[2] = "iam"; parts[5] = "role/" + resource[1]
        } else if parts[2] == "iam", resource.count >= 2, resource[0] == "role" {
            parts[5] = "role/" + resource[resource.count - 1]
        }
        return parts.joined(separator: ":")
    }
}

private struct SharedAWSLocalSource: Codable {
    var descriptor: AWSProfileDescriptor
    var lastAttempt: Double = 0
    var lastExpiry: Double = 0
    var failed: Bool = false
}
private struct SharedAWSLocalDocument: Codable {
    var sources: [String: SharedAWSLocalSource] = [:]
}

// A separate service intentionally keeps AWS's rotating login material on the
// Mac that owns it. Paired Macs receive only expiring account/role credentials.
final class SharedAWSService {
    private let queue = DispatchQueue(label: "com.terminaldb.aws")
    private let root: URL
    private let configuration: AWSProfileConfiguration
    private let store: SharedAWSStore
    private var refreshTimer: DispatchSourceTimer?
    private var document = SharedAWSLocalDocument()
    private var loaded = false
    private var jobs: [String: SharedAWSCommand] = [:]
    private var renewing: Set<String> = []
    private var signInProfile: String?
    private var signInSessionKey: String?
    private var signInRenewalGeneration: UInt64 = 0
    private var phase = ""
    private var sourceStatus: [String: String] = [:]
    private static let maximumLocalSources = 16
    var changed: (() -> Void)?

    init(root: URL = PeerPaths.root) {
        self.root = root
        let config = SharedAccountCodeIdentity.fixture
            ? root.appendingPathComponent("aws-fixture/config")
            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".aws/config")
        configuration = AWSProfileConfiguration(configURL: config, root: root.appendingPathComponent("aws-profiles"))
        store = SharedAWSStore(root: root)
    }
    func start() {
        queue.async {
            guard self.refreshTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 2, repeating: 60)
            timer.setEventHandler { [weak self] in self?.refreshEligible() }
            self.refreshTimer = timer; timer.resume()
        }
    }
    deinit { refreshTimer?.cancel() }

    func handle(_ operation: String, payload: [String: Any], audit: Data? = nil, authenticate: Bool = false,
                completion: @escaping ([String: Any]) -> Void) {
        queue.async {
            let reply: ([String: Any]) -> Void = { value in DispatchQueue.main.async { completion(value) } }
            do {
                if authenticate && operation != "aws.catalog" {
                    let authorized: Bool
                    if operation == "aws.credentials" {
                        authorized = audit.map { SharedAccountCodeIdentity.allowsCredentialLauncher(audit: $0) } ?? false
                    } else {
                        authorized = audit.map { SharedAccountCodeIdentity.allowsLocalManagement(audit: $0) } ?? false
                    }
                    guard authorized else { throw PeerFailure("Use the installed TerminalDB app to manage AWS access.") }
                }
                try self.load()
                if self.signInProfile == nil && ["aws.source.enable", "aws.share", "aws.use", "aws.remove", "aws.refresh"].contains(operation) {
                    self.phase = ""
                }
                switch operation {
                case "aws.catalog": reply(try self.catalog())
                case "aws.check": reply(["accepted": true])
                case "aws.sync.digest": reply(["digest": try self.store.digest()])
                case "aws.sync.export": reply(["bundle": try self.store.exportBundle()])
                case "aws.sync.import":
                    guard let bundle = payload["bundle"] as? [String: Any] else { throw PeerFailure("The AWS credential transfer is incomplete.") }
                    try self.store.importBundle(bundle); self.notify(); reply(["accepted": true])
                case "aws.source.enable":
                    guard let id = payload["profileId"] as? String, Self.validID(id),
                          let profile = try self.configuration.discover().first(where: { $0.id == id }) else {
                        throw PeerFailure("Choose an AWS SSO or browser-login profile configured on this Mac, or use Sign In first.")
                    }
                    guard !self.isSigningIn(profile) else { throw PeerFailure("Complete or cancel this AWS session sign-in before sharing its current access.") }
                    guard self.document.sources[id] != nil || self.document.sources.count < Self.maximumLocalSources else {
                        throw PeerFailure("Share up to 16 AWS profiles from this Mac. Stop sharing one before adding another.")
                    }
                    // Native source profiles keep their existing AWS commands
                    // and configuration. Only selected temporary credentials
                    // are published; no credential_process mapping is needed.
                    _ = try self.configuration.prepareBackingConfig(profile)
                    let changed = try self.saveSource(profile)
                    if changed { self.cancelRefresh(id) }
                    self.refresh(id, manual: true)
                    self.notify(); reply(try self.catalog())
                case "aws.share", "aws.use":
                    let profile = try self.profile(payload)
                    let target = payload["targetName"] as? String ?? profile.name
                    if operation == "aws.share" {
                        guard !self.isSigningIn(profile) else { throw PeerFailure("Complete or cancel this AWS session sign-in before sharing its current access.") }
                        guard try self.localProfiles().contains(where: { $0.id == profile.id }) else {
                            throw PeerFailure("Sign in on this Mac before sharing this AWS profile.")
                        }
                        guard self.document.sources[profile.id] != nil || self.document.sources.count < Self.maximumLocalSources else {
                            throw PeerFailure("Share up to 16 AWS profiles from this Mac. Stop sharing one before adding another.")
                        }
                    }
                    let previousInstallation = try self.configuration.installations().first { $0.targetName == target }
                    let installation = try self.configuration.install(profile, targetName: target, launcherPath: TDBSharedAWS.launcherPath,
                                                                      allowReplacingSource: payload["replaceSource"] as? Bool == true)
                    if operation == "aws.share" {
                        do {
                            let changed = try self.saveSource(profile)
                            if changed { self.cancelRefresh(profile.id) }
                        }
                        catch {
                            if previousInstallation == nil { try? self.configuration.restore(installation) }
                            throw error
                        }
                        self.refresh(profile.id, manual: true)
                    }
                    self.notify(); reply(try self.catalog())
                case "aws.signIn.start":
                    guard self.signInProfile == nil else { throw PeerFailure("Complete or cancel the AWS sign-in already open in your browser.") }
                    let profile = try self.profile(payload)
                    guard self.document.sources[profile.id] != nil || self.document.sources.count < Self.maximumLocalSources else {
                        throw PeerFailure("Share up to 16 AWS profiles from this Mac. Stop sharing one before adding another.")
                    }
                    // One browser sign-in owns the SSO session, not just its
                    // selected account/role. Fence every related renewal before
                    // authentication so old exports cannot overwrite new access.
                    let sessionKey = try self.sessionKey(for: profile)
                    self.signInRenewalGeneration &+= 1
                    let renewalGeneration = self.signInRenewalGeneration
                    for source in Array(self.document.sources.values) where source.descriptor.id == profile.id || (sessionKey != nil && (try? self.sessionKey(for: source.descriptor)) == sessionKey) {
                        self.cancelRefresh(source.descriptor.id)
                    }
                    guard self.jobs.count < 4 else {
                        throw PeerFailure("AWS is renewing other profiles. Try Sign In again in a moment.")
                    }
                    // New enrollment remains explicit and happens only after
                    // authentication succeeds, never from a sibling profile.
                    let config = try self.configuration.prepareBackingConfig(profile)
                    let executable = try SharedAWSCLI.executable(root: self.root)
                    let environment = try SharedAWSCLI.environment(root: self.root, config: config)
                    let command = SharedAWSCommand(queue: self.queue)
                    let key = "signin:" + profile.id
                    self.jobs[key] = command; self.signInProfile = profile.id; self.signInSessionKey = sessionKey
                    self.phase = profile.kind == "sso" ? "Complete AWS sign-in in your browser. This signs in all profiles using this SSO session on this Mac." : "Complete AWS sign-in in your browser on this Mac."
                    self.notify()
                    var launched = false
                    defer {
                        if !launched {
                            self.jobs.removeValue(forKey: key); self.signInProfile = nil; self.signInSessionKey = nil
                            command.cancel()
                        }
                    }
                    try command.start(executable: executable, arguments: try self.configuration.loginArguments(for: profile),
                                      environment: environment, timeout: 600, capture: false) { [weak self, weak command] result in
                        guard let self, let command, self.jobs[key] === command else { return }
                        self.jobs.removeValue(forKey: key); self.signInProfile = nil; self.signInSessionKey = nil
                        switch result {
                        case .success:
                            do {
                                _ = try self.saveSource(profile, forceRenewal: true)
                                let related = Array(self.document.sources.values).filter {
                                    $0.descriptor.id == profile.id || (sessionKey != nil && (try? self.sessionKey(for: $0.descriptor)) == sessionKey)
                                }.map { $0.descriptor.id }
                                for id in related {
                                    self.document.sources[id]?.lastAttempt = 0
                                    self.document.sources[id]?.lastExpiry = 0
                                    self.document.sources[id]?.failed = false
                                }
                                try self.save()
                                if profile.kind == "sso" {
                                    let state = self.configuration.authenticationStatus(for: profile)["state"] as? String
                                    if state == "current" {
                                        self.phase = "SSO session signed in. Its profiles can renew access on this Mac."
                                    } else if state == "expired" || state == "missing" {
                                        self.phase = "AWS sign-in finished, but this SSO session still needs sign-in. Choose Sign In again. Cached profile access is kept until it expires."
                                    } else {
                                        self.phase = "AWS sign-in finished, but its SSO status could not be verified. Check the session status before relying on renewal."
                                    }
                                } else {
                                    self.phase = "Signed in. Your approved Macs receive renewed credentials when connected."
                                }
                                self.refreshSignedInSources(related, generation: renewalGeneration)
                            } catch {
                                self.phase = "AWS sign-in finished locally, but sharing could not be saved. Open AWS Access and try again."
                            }
                        case .failure:
                            self.phase = "AWS sign-in did not finish. Try Sign In again. Existing cached profile access is kept until it expires."
                        }
                        self.notify()
                    }
                    launched = true
                    reply(["accepted": true])
                case "aws.signIn.cancel":
                    self.cancelSignIn()
                    self.phase = "AWS sign-in cancelled. Existing cached profile access is kept until it expires."; self.notify(); reply(["accepted": true])
                case "aws.refresh":
                    if let id = payload["profileId"] as? String {
                        guard self.document.sources[id] != nil else { throw PeerFailure("Sign in on this Mac to renew this AWS profile.") }
                        self.refresh(id, manual: true)
                    } else { self.refreshEligible(manual: true) }
                    reply(["accepted": true])
                case "aws.remove":
                    let profile = try self.profile(payload)
                    if self.signInProfile == profile.id { self.cancelSignIn() }
                    let previous = self.document.sources.removeValue(forKey: profile.id)
                    do { try self.save() }
                    catch { self.document.sources[profile.id] = previous; throw error }
                    try self.store.withdraw(profile.id)
                    self.sourceStatus.removeValue(forKey: profile.id)
                    self.cancelRefresh(profile.id)
                    var incomplete = false
                    for installation in try self.configuration.installations() where installation.descriptor.id == profile.id {
                        do { try self.configuration.restore(installation) }
                        catch { incomplete = true }
                    }
                    if self.signInProfile == nil { self.phase = "" }
                    if incomplete {
                        self.notify()
                        throw PeerFailure("Sharing from this Mac has stopped. Some edited or unavailable profile names could not be restored safely; other names were restored where possible. Your configuration changes were kept.")
                    }
                    self.notify(); reply(try self.catalog())
                case "aws.credentials":
                    guard let id = payload["profileId"] as? String, Self.validID(id) else { throw PeerFailure("Choose a configured AWS profile.") }
                    do {
                        let credentials = try self.store.credentials(forProfile: id)
                        self.refresh(id, manual: false)
                        reply(["credentials": credentials.processOutput()])
                    } catch {
                        guard let source = self.document.sources[id], !self.renewing.contains(id), !self.isSigningIn(source.descriptor) else { throw error }
                        self.document.sources[id]?.lastExpiry = 0
                        self.refresh(id, manual: false) {
                            do { reply(["credentials": try self.store.credentials(forProfile: id).processOutput()]) }
                            catch { reply(["error": "AWS credentials are expired. Sign in on this Mac or reconnect a signed-in Mac."]) }
                        }
                    }
                default: throw PeerFailure("This AWS operation is unsupported.")
                }
            } catch {
                let text = (error as? PeerFailure)?.message ?? "AWS access could not finish. Open AWS Access to check this profile."
                reply(["error": text])
            }
        }
    }

    private static func validID(_ value: String) -> Bool { value.count == 64 && value.allSatisfy(\.isHexDigit) }
    private func load() throws {
        guard !loaded else { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = root.appendingPathComponent("aws-service.json")
        if FileManager.default.fileExists(atPath: path.path) {
            let data = try Data(contentsOf: path)
            guard data.count <= 1_048_576 else { throw PeerFailure("Too many AWS profiles are configured.") }
            document = try JSONDecoder().decode(SharedAWSLocalDocument.self, from: data)
            guard document.sources.count <= Self.maximumLocalSources else { throw PeerFailure("Too many AWS profiles are configured.") }
            for (id, source) in document.sources {
                try source.descriptor.validate()
                guard id == source.descriptor.id, source.lastAttempt.isFinite, source.lastExpiry.isFinite else { throw PeerFailure("The local AWS source record is invalid.") }
            }
        }
        loaded = true
    }
    private func save() throws {
        guard document.sources.count <= Self.maximumLocalSources else { throw PeerFailure("Too many AWS profiles are configured.") }
        let path = root.appendingPathComponent("aws-service.json")
        try JSONEncoder().encode(document).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
    @discardableResult private func saveSource(_ profile: AWSProfileDescriptor, forceRenewal: Bool = false) throws -> Bool {
        let previous = document.sources[profile.id]
        guard previous != nil || document.sources.count < Self.maximumLocalSources else { throw PeerFailure("Share up to 16 AWS profiles from this Mac.") }
        let changed = previous?.descriptor != profile
        var source = previous ?? SharedAWSLocalSource(descriptor: profile)
        source.descriptor = profile
        if changed || forceRenewal { source.lastAttempt = 0; source.lastExpiry = 0; source.failed = false }
        document.sources[profile.id] = source
        do { try save() }
        catch { document.sources[profile.id] = previous; throw error }
        return changed
    }
    private func cancelRefresh(_ id: String) {
        // Detach before cancelling: cancelled process callbacks must not update
        // a newer alias, renewal, or removal for this persistent profile ID.
        let command = jobs.removeValue(forKey: "refresh:" + id)
        renewing.remove(id)
        command?.cancel()
    }
    // Resolve only local, validated metadata. A shared account/role identity
    // does not imply that two aliases use the same local SSO login session.
    private func sessionKey(for profile: AWSProfileDescriptor) throws -> String? {
        guard profile.kind == "sso" else { return nil }
        let name = try configuration.resolvedSSOSessionName(for: profile) ?? ""
        let data = try JSONSerialization.data(withJSONObject: [profile.ssoStartURL, profile.ssoRegion, name])
        return AWSProfileDescriptor.hash(data)
    }
    private func isSigningIn(_ profile: AWSProfileDescriptor) -> Bool {
        guard signInProfile != nil else { return false }
        if profile.id == signInProfile { return true }
        guard let signInSessionKey else { return false }
        return (try? sessionKey(for: profile)) == signInSessionKey
    }
    private func cancelSignIn() {
        guard let id = signInProfile else { return }
        // Detach first: a cancelled process may report termination after a
        // newer browser login starts. It must not clear that new operation.
        let command = jobs.removeValue(forKey: "signin:" + id)
        signInProfile = nil; signInSessionKey = nil
        command?.cancel()
    }
    private func refreshSignedInSources(_ ids: [String], generation: UInt64) {
        guard generation == signInRenewalGeneration, let id = ids.first else { return }
        // Run in bounded batches even when the SSO session has many profiles.
        // Every refresh rechecks source enrollment and the selected descriptor.
        if jobs.count >= 4 {
            queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.refreshSignedInSources(ids, generation: generation) }
            return
        }
        refresh(id, manual: true) { [weak self] in self?.refreshSignedInSources(Array(ids.dropFirst()), generation: generation) }
    }
    private func localProfiles() throws -> [AWSProfileDescriptor] {
        var profiles = try configuration.discover()
        for source in document.sources.values where !profiles.contains(where: { $0.id == source.descriptor.id }) { profiles.append(source.descriptor) }
        return profiles
    }
    private func profile(_ payload: [String: Any]) throws -> AWSProfileDescriptor {
        guard let id = payload["profileId"] as? String, Self.validID(id) else { throw PeerFailure("Choose an AWS profile first.") }
        if let result = try localProfiles().first(where: { $0.id == id }) { return result }
        if let result = try configuration.installations().first(where: { $0.descriptor.id == id }) { return result.descriptor }
        if let result = try store.profiles().first(where: { $0.id == id }) { return result }
        throw PeerFailure("This AWS profile is no longer available. Reconnect the Mac that shared it.")
    }
    private func catalog() throws -> [String: Any] {
        let local = try localProfiles()
        let profiles = try local.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
        var authentication: [String: [String: Any]] = [:]
        for profile in local where authentication[profile.id] == nil { authentication[profile.id] = configuration.authenticationStatus(for: profile) }
        let installed: [[String: Any]] = try configuration.installations().map {
            ["profileId": $0.descriptor.id, "targetName": $0.targetName, "source": document.sources[$0.descriptor.id] != nil,
             "descriptor": try JSONSerialization.jsonObject(with: JSONEncoder().encode($0.descriptor))]
        }
        return ["profiles": profiles, "accounts": try store.catalog(), "installed": installed,
                "configuredProfileIDs": Array(Set(try configuration.discover().map(\.id))).sorted(),
                "localProfileNames": try configuration.configuredNames(),
                "phase": phase, "sourceStatus": sourceStatus, "signInProfile": signInProfile ?? "",
                "signInProfiles": Array(Set(local.filter { isSigningIn($0) }.map(\.id))).sorted(),
                "authentication": authentication,
                "sources": document.sources.keys.sorted()]
    }
    private func notify() { DispatchQueue.main.async { self.changed?() } }

    private func refreshEligible(manual: Bool = false) {
        do {
            try load()
            for id in document.sources.keys.sorted(by: { (document.sources[$0]?.lastAttempt ?? 0) < (document.sources[$1]?.lastAttempt ?? 0) }) { refresh(id, manual: manual) }
        } catch { /* The native catalog reports recoverable configuration failures. */ }
    }
    private func refresh(_ id: String, manual: Bool, completion: (() -> Void)? = nil) {
        guard let source = document.sources[id], !renewing.contains(id), !isSigningIn(source.descriptor), jobs.count < 4 else { completion?(); return }
        let now = Date().timeIntervalSince1970
        guard manual || source.lastExpiry <= now + 300 else { completion?(); return }
        guard manual || !source.failed || now < source.lastAttempt || now - source.lastAttempt >= 300 else { completion?(); return }
        renewing.insert(id)
        document.sources[id]?.lastAttempt = now
        sourceStatus[id] = "Renewing…"
        try? save()
        do {
            let profile = source.descriptor
            let config = try configuration.prepareBackingConfig(profile)
            let executable = try SharedAWSCLI.executable(root: root)
            let environment = try SharedAWSCLI.environment(root: root, config: config)
            let key = "refresh:" + id
            let command = SharedAWSCommand(queue: queue); jobs[key] = command
            try command.start(executable: executable,
                              arguments: ["configure", "export-credentials", "--profile", profile.name, "--format", "process", "--no-cli-pager", "--cli-connect-timeout", "5", "--cli-read-timeout", "10"],
                                      environment: environment, timeout: 25, capture: true) { [weak self, weak command] result in
                guard let self else { return }
                guard let command, self.jobs[key] === command else { completion?(); return }
                self.jobs.removeValue(forKey: key)
                do {
                    let data = try result.get()
                    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PeerFailure("AWS returned an invalid credential response.") }
                    let credentials = try AWSRoleCredentials(process: value)
                    try credentials.validate(now: Date().timeIntervalSince1970, syntheticOnly: SharedAccountCodeIdentity.fixture)
                    self.verifyAndPublish(profile, credentials: credentials, executable: executable, config: config, completion: completion)
                } catch { self.finishRefresh(id, expiry: nil); completion?() }
            }
        } catch { jobs.removeValue(forKey: "refresh:" + id); finishRefresh(id, expiry: nil); completion?() }
    }
    private func verifyAndPublish(_ profile: AWSProfileDescriptor, credentials: AWSRoleCredentials, executable: URL,
                                  config: URL, completion: (() -> Void)?) {
        do {
            let key = "refresh:" + profile.id
            let environment = try SharedAWSCLI.environment(root: root, config: config, credentials: credentials,
                                                          region: profile.region.isEmpty ? profile.ssoRegion : profile.region)
            let command = SharedAWSCommand(queue: queue); jobs[key] = command
            try command.start(executable: executable,
                              arguments: ["sts", "get-caller-identity", "--output", "json", "--no-cli-pager", "--cli-connect-timeout", "5", "--cli-read-timeout", "10"],
                              environment: environment, timeout: 20, capture: true) { [weak self, weak command] result in
                guard let self else { return }
                guard let command, self.jobs[key] === command else { completion?(); return }
                self.jobs.removeValue(forKey: key)
                do {
                    guard self.document.sources[profile.id]?.descriptor == profile else { throw PeerFailure("The AWS source selection changed.") }
                    let data = try result.get()
                    guard let identity = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PeerFailure("AWS returned an invalid account identity.") }
                    let arn = try SharedAWSPrincipal.verify(identity, profile: profile)
                    _ = try self.store.publish(profile: profile, principalARN: arn, credentials: credentials,
                                               sourceName: PeerProtocol.displayName(Host.current().localizedName ?? "This Mac"))
                    self.finishRefresh(profile.id, expiry: credentials.expiration)
                } catch { self.finishRefresh(profile.id, expiry: nil) }
                completion?()
            }
        } catch { finishRefresh(profile.id, expiry: nil); completion?() }
    }
    private func finishRefresh(_ id: String, expiry: Double?) {
        renewing.remove(id)
        guard document.sources[id] != nil else { return }
        document.sources[id]?.failed = expiry == nil
        if let expiry { document.sources[id]?.lastExpiry = expiry; sourceStatus[id] = "Ready to share" }
        else { sourceStatus[id] = "Sign in on this Mac to renew" }
        try? save(); notify()
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refreshEligible() }
    }
}

@objc public final class TDBSharedAWS: NSObject {
    @objc public static var launcherPath: String {
        if Bundle.main.bundleIdentifier == "com.terminaldb.session-host" { return Bundle.main.executablePath ?? "" }
        var app = Bundle.main.bundleURL
        if app.lastPathComponent == "TerminalDBPeerAgent.app" { for _ in 0..<4 { app.deleteLastPathComponent() } }
        return app.appendingPathComponent("Contents/Library/LoginItems/TerminalDBSessionHost.app/Contents/MacOS/TerminalDBSessionHost").path
    }
    // This mode runs before AppKit. stdout belongs exclusively to AWS's
    // documented credential_process protocol; diagnostics are fixed text.
    @objc public static func runLauncherIfRequested() -> Int32 {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.count > 1, arguments[1] == "--aws-credentials" else { return -1 }
        guard arguments.count == 3, arguments[2].count == 64, arguments[2].allSatisfy(\.isHexDigit) else { return 64 }
        do {
            let response = try SharedAWSCredentialRPC.request(profileID: arguments[2])
            guard let payload = response["credentials"] as? [String: Any] else { throw PeerFailure("AWS credentials are unavailable.") }
            let credential = try AWSRoleCredentials(process: payload)
            let output = try JSONSerialization.data(withJSONObject: credential.processOutput(), options: [.sortedKeys]) + Data([10])
            _ = signal(SIGPIPE, SIG_IGN)
            var written = 0
            try output.withUnsafeBytes { bytes in
                while written < bytes.count {
                    let count = Darwin.write(STDOUT_FILENO, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw PeerFailure("The AWS consumer disconnected.") }
                    written += count
                }
            }
            return 0
        } catch {
            fputs("TerminalDB: AWS credentials are unavailable or expired. Open AWS Access, reconnect your LAN or VPN, or sign in on this Mac.\n", stderr)
            return 1
        }
    }
}

private enum SharedAWSCredentialRPC {
    static func request(profileID: String) throws -> [String: Any] {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw PeerFailure("The AWS credential service is unavailable.") }
        defer { Darwin.close(descriptor) }
        let deadline = ProcessInfo.processInfo.systemUptime + 50
        guard fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) == 0 else {
            throw PeerFailure("The AWS credential service is unavailable.")
        }
        var noSignal: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(PeerPaths.file("host.sock").path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw PeerFailure("The AWS credential service is unavailable.") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if connected != 0 {
            guard errno == EINPROGRESS else { throw PeerFailure("The AWS credential service is unavailable.") }
            try wait(descriptor, events: Int16(POLLOUT), deadline: deadline)
            var error: Int32 = 0; var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else {
                throw PeerFailure("The AWS credential service is unavailable.")
            }
        }
        let secret = try Data(contentsOf: PeerPaths.file("host.secret"))
        guard secret.count <= 4096, let key = String(data: secret, encoding: .utf8) else { throw PeerFailure("The AWS credential service is unavailable.") }
        try send(["type": "hello", "version": PeerProtocol.version, "clientId": UUID().uuidString, "secret": key], descriptor: descriptor, deadline: deadline)
        guard try read(descriptor, deadline: deadline)["type"] as? String == "ready" else { throw PeerFailure("The AWS credential service is unavailable.") }
        let id = UUID().uuidString
        try send(["type": "request", "requestId": id, "operation": "aws.credentials", "profileId": profileID], descriptor: descriptor, deadline: deadline)
        for _ in 0..<16 {
            let response = try read(descriptor, deadline: deadline)
            if response["requestId"] as? String == id { return response }
        }
        throw PeerFailure("The AWS credential service is unavailable.")
    }
    private static func wait(_ descriptor: Int32, events: Int16, deadline: Double) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw PeerFailure("The AWS credential service did not finish in time.") }
            var fd = pollfd(fd: descriptor, events: events, revents: 0)
            let ready = poll(&fd, 1, Int32(min(50_000, ceil(remaining * 1000))))
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0, fd.revents & events != 0 else { throw PeerFailure("The AWS credential service is unavailable.") }
            return
        }
    }
    private static func send(_ value: [String: Any], descriptor: Int32, deadline: Double) throws {
        var body = try JSONSerialization.data(withJSONObject: value)
        guard body.count <= 16_384 else { throw PeerFailure("The AWS credential request is invalid.") }
        var length = UInt32(body.count).bigEndian
        var frame = Data(bytes: &length, count: 4); frame.append(body)
        defer { body.resetBytes(in: 0..<body.count) }
        var offset = 0
        try frame.withUnsafeBytes { bytes in
            while offset < bytes.count {
                try wait(descriptor, events: Int16(POLLOUT), deadline: deadline)
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
                guard count > 0 else { throw PeerFailure("The AWS credential service is unavailable.") }
                offset += count
            }
        }
    }
    private static func read(_ descriptor: Int32, deadline: Double) throws -> [String: Any] {
        func exact(_ length: Int) throws -> Data {
            var result = Data(count: length), offset = 0
            try result.withUnsafeMutableBytes { bytes in
                while offset < bytes.count {
                    try wait(descriptor, events: Int16(POLLIN), deadline: deadline)
                    let count = Darwin.read(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
                    guard count > 0 else { throw PeerFailure("The AWS credential service is unavailable.") }
                    offset += count
                }
            }
            return result
        }
        let length = try exact(4).reduce(0) { ($0 << 8) | Int($1) }
        guard length > 1, length <= 65_536 else { throw PeerFailure("The AWS credential response is invalid.") }
        var bytes = try exact(length)
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        guard let result = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw PeerFailure("The AWS credential response is invalid.")
        }
        return result
    }
}

// Exercises the provider boundary using temporary files and synthetic process
// data. No AWS service, user configuration, Keychain or browser is involved.
enum SharedAWSServiceTests {
    static func run(root: URL) throws -> Int {
        var checks = 0
        func check(_ result: @autoclosure () throws -> Bool) throws {
            guard try result() else { throw PeerFailure("An AWS provider boundary regression failed after \(checks) checks.") }
            checks += 1
        }
        func rejected(_ action: () throws -> Void) -> Bool { do { try action(); return false } catch { return true } }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let profile = AWSProfileDescriptor(name: "Synthetic AWS", kind: "sso", region: "us-east-1", ssoStartURL: "https://example.awsapps.com/start", ssoRegion: "us-east-1", accountID: "123456789012", roleName: "ReadOnly", ssoSessionName: "synthetic")
        let arn = "arn:aws:sts::123456789012:assumed-role/AWSReservedSSO_ReadOnly_0123456789abcdef/synthetic"
        try check(try SharedAWSPrincipal.verify(["Account": "123456789012", "Arn": arn], profile: profile) == arn)
        try check(rejected { _ = try SharedAWSPrincipal.verify(["Account": "210987654321", "Arn": arn], profile: profile) })
        try check(rejected { _ = try SharedAWSPrincipal.verify(["Account": "123456789012", "Arn": "arn:aws:sts::123456789012:assumed-role/AWSReservedSSO_Admin_0123456789abcdef/synthetic"], profile: profile) })
        try check(rejected { _ = try SharedAWSPrincipal.verify(["Account": "123456789012", "Arn": "arn:aws:sts::123456789012:assumed-role/ReadOnly/synthetic"], profile: profile) })
        try check(rejected { _ = try SharedAWSPrincipal.verify(["Account": "123456789012", "Arn": "arn:aws:iam::123456789012:user/synthetic"], profile: profile) })
        let login = AWSProfileDescriptor(name: "Synthetic Login", kind: "login", region: "us-east-1", accountID: "123456789012", loginSession: "arn:aws:iam::123456789012:role/path/Example")
        let loginARN = "arn:aws:sts::123456789012:assumed-role/Example/synthetic"
        try check(try SharedAWSPrincipal.verify(["Account": "123456789012", "Arn": loginARN], profile: login) == loginARN)
        try check(rejected { _ = try SharedAWSPrincipal.verify(["Account": "123456789012", "Arn": "arn:aws:sts::123456789012:assumed-role/Other/synthetic"], profile: login) })
        let previous = ProcessInfo.processInfo.environment["AWS_ENDPOINT_URL"]
        setenv("AWS_ENDPOINT_URL", "https://example.invalid", 1)
        defer { if let previous { setenv("AWS_ENDPOINT_URL", previous, 1) } else { unsetenv("AWS_ENDPOINT_URL") } }
        let environment = try SharedAWSCLI.environment(root: root, config: root.appendingPathComponent("empty.config"))
        try check(environment["AWS_ENDPOINT_URL"] == nil)
        try check(environment["AWS_ACCESS_KEY_ID"] == nil && environment["AWS_SECRET_ACCESS_KEY"] == nil && environment["AWS_SESSION_TOKEN"] == nil)
        try check(environment["AWS_PROFILE"] == nil && environment["PYTHONPATH"] == nil && environment["DYLD_INSERT_LIBRARIES"] == nil)
        try check(environment["AWS_EC2_METADATA_DISABLED"] == "true" && environment["AWS_CLI_AUTO_PROMPT"] == "off")
        try check(try Data(contentsOf: root.appendingPathComponent("aws-empty-credentials")).isEmpty)
        let fixture = AWSRoleCredentials(accessKeyId: "tdb-test-access-key", secretAccessKey: "tdb-test-secret-key", sessionToken: "tdb-test-session-token", expiration: Date().addingTimeInterval(600).timeIntervalSince1970)
        let scoped = try SharedAWSCLI.environment(root: root, config: root.appendingPathComponent("empty.config"), credentials: fixture, region: "us-east-1")
        try check(scoped["AWS_ACCESS_KEY_ID"] == fixture.accessKeyId && scoped["AWS_DEFAULT_REGION"] == "us-east-1")
        let runner = root.appendingPathComponent("synthetic-process")
        func process(_ script: String, timeout: Double = 3, expectSuccess: Bool) throws -> Bool {
            try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: runner, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runner.path)
            let queue = DispatchQueue(label: "com.terminaldb.aws.boundary-test")
            let command = SharedAWSCommand(queue: queue)
            let complete = DispatchSemaphore(value: 0)
            final class ResultBox { var succeeded = false }
            let result = ResultBox()
            queue.async {
                do {
                    try command.start(executable: runner, arguments: [], environment: ["PATH": "/usr/bin:/bin"], timeout: timeout, capture: true) { response in
                        switch response {
                        case .success: result.succeeded = expectSuccess
                        case .failure: result.succeeded = !expectSuccess
                        }
                        complete.signal()
                    }
                } catch { result.succeeded = !expectSuccess; complete.signal() }
            }
            guard complete.wait(timeout: .now() + 5) == .success else { queue.async { command.cancel() }; return false }
            return result.succeeded
        }
        try check(try process("printf '%s' 'synthetic response'", expectSuccess: true))
        try check(try process("exit 1", expectSuccess: false))
        try check(try process("/usr/bin/yes synthetic | /usr/bin/head -c 70000", expectSuccess: false))
        try check(try process("/bin/sleep 2", timeout: 0.05, expectSuccess: false))
        checks += try flow(root: root.appendingPathComponent("flow"))
        return checks
    }

    private static func flow(root: URL) throws -> Int {
        let variables = ["TERMINALDB_PEER_QA", "TERMINALDB_PEER_EPHEMERAL_IDENTITY", "TERMINALDB_PEER_STATE_DIR", "TERMINALDB_AWS_QA_EXECUTABLE"]
        let previous = ProcessInfo.processInfo.environment
        defer {
            for key in variables {
                if let value = previous[key] { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("aws-fixture"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fake = root.appendingPathComponent("aws")
        setenv("TERMINALDB_PEER_QA", "1", 1); setenv("TERMINALDB_PEER_EPHEMERAL_IDENTITY", "1", 1)
        setenv("TERMINALDB_PEER_STATE_DIR", root.path, 1); setenv("TERMINALDB_AWS_QA_EXECUTABLE", fake.path, 1)
        let program = """
        #!/usr/bin/python3
        import sys,json,datetime,os,time,configparser,hashlib,fcntl
        from pathlib import Path
        args=sys.argv[1:]
        if (Path(os.environ['HOME'])/'capture-config').exists():
            profile=args[args.index('--profile')+1] if '--profile' in args else ''
            call={'operation':args[0], 'profile':profile, 'session':args[args.index('--sso-session')+1] if '--sso-session' in args else '', 'config':Path(os.environ['AWS_CONFIG_FILE']).read_text()}
            with (Path(os.environ['HOME'])/'fixture-calls.jsonl').open('a') as output: output.write(json.dumps(call)+'\\n')
        if args[:2]==['configure','export-credentials']:
            if (Path(os.environ['HOME'])/'export-delay').exists():
                (Path(os.environ['HOME'])/'export-started').write_text('ready')
                time.sleep(8)
            generation=('-'+(Path(os.environ['HOME'])/'generation').read_text()) if (Path(os.environ['HOME'])/'generation').exists() else ''
            expiry=Path(os.environ['HOME'])/('expiration'+generation)
            # Parallel role exports share one stable, fully written expiry per generation.
            with (Path(os.environ['HOME'])/'expiration.lock').open('a') as lock:
                fcntl.flock(lock.fileno(),fcntl.LOCK_EX)
                if not expiry.exists(): expiry.write_text((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(minutes=10)).isoformat())
                expiration=expiry.read_text()
            print(json.dumps({'Version':1,'AccessKeyId':'tdb-test-access-key'+generation,'SecretAccessKey':'tdb-test-secret-key'+generation,'SessionToken':'tdb-test-session-token'+generation,'Expiration':expiration}))
        elif args[:2]==['sts','get-caller-identity']:
            config=configparser.RawConfigParser(); config.read(os.environ['AWS_CONFIG_FILE'])
            section=next(s for s in config.sections() if s.startswith('profile ') or s=='default')
            account=config.get(section,'sso_account_id'); role=config.get(section,'sso_role_name')
            print(json.dumps({'Account':account,'Arn':'arn:aws:sts::'+account+':assumed-role/AWSReservedSSO_'+role+'_0123456789abcdef/synthetic'}))
        elif args[:2]==['sso','login']:
            if (Path(os.environ['HOME'])/'signin-delay').exists():
                (Path(os.environ['HOME'])/'signin-started').write_text('ready')
                time.sleep(0.8)
            if (Path(os.environ['HOME'])/'signin-fail').exists(): sys.exit(1)
            if '--sso-session' in args:
                session=args[args.index('--sso-session')+1]
                config=configparser.RawConfigParser(); config.read(os.environ['AWS_CONFIG_FILE'])
                section='sso-session '+session
                cache=Path(os.environ['HOME'])/'.aws/sso/cache'; cache.mkdir(parents=True,exist_ok=True)
                token=cache/(hashlib.sha1(session.encode()).hexdigest()+'.json')
                token.write_text(json.dumps({'accessToken':'tdb-test-sso-token','startUrl':config.get(section,'sso_start_url'),'region':config.get(section,'sso_region'),'expiresAt':(datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=1)).strftime('%Y-%m-%dT%H:%M:%SZ')}))
                token.chmod(0o600)
        else: sys.exit(1)
        """
        try Data(program.utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let config = root.appendingPathComponent("aws-fixture/config")
        let original = Data("[profile test]\nsso_start_url = https://example.awsapps.com/start\nsso_region = us-east-1\nsso_account_id = 123456789012\nsso_role_name = ReadOnly\n\n[profile static-fixture]\naws_access_key_id = tdb-test-static-access\naws_secret_access_key = tdb-test-static-secret\n".utf8)
        try original.write(to: config)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        let service = SharedAWSService(root: root)
        func request(_ operation: String, _ payload: [String: Any] = [:], authenticate: Bool = false) throws -> [String: Any] {
            var response: [String: Any]?
            service.handle(operation, payload: payload, authenticate: authenticate) { response = $0 }
            let deadline = Date().addingTimeInterval(10)
            while response == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            guard let response else { throw PeerFailure("The synthetic AWS service did not finish.") }
            return response
        }
        var count = 0
        func check(_ result: @autoclosure () throws -> Bool) throws {
            guard try result() else { throw PeerFailure("An AWS service flow regression failed after \(count) checks.") }; count += 1
        }
        let before = try request("aws.catalog")
        guard let descriptor = (before["profiles"] as? [[String: Any]])?.first,
              let id = descriptor["id"] as? String else { throw PeerFailure("The synthetic AWS profile was not discovered.") }
        // A native source can publish its existing login without replacing
        // the profile or changing ordinary aws sso login commands.
        try check(try request("aws.source.enable", ["profileId": id], authenticate: true)["error"] != nil)
        try check((try request("aws.catalog")["sources"] as? [String])?.isEmpty == true)
        let unsupported = AWSProfileDescriptor(name: "static-fixture", kind: "login", loginSession: "arn:aws:iam::123456789012:user/synthetic-static")
        try check(try request("aws.source.enable", ["profileId": unsupported.id])["error"] != nil)
        try check(try Data(contentsOf: config) == original)
        let enabled = try request("aws.source.enable", ["profileId": id])
        try check(enabled["error"] == nil)
        try check((enabled["sources"] as? [String]) == [id])
        try check((enabled["installed"] as? [[String: Any]])?.isEmpty == true)
        try check(try Data(contentsOf: config) == original)
        let nativeDeadline = Date().addingTimeInterval(10)
        var nativeReady = false
        while !nativeReady && Date() < nativeDeadline {
            nativeReady = (try request("aws.credentials", ["profileId": id])["credentials"] as? [String: Any]) != nil
            if !nativeReady { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        }
        try check(nativeReady)
        try check(try Data(contentsOf: config) == original)
        let nativeRemoved = try request("aws.remove", ["profileId": id])
        try check(nativeRemoved["error"] == nil)
        try check((nativeRemoved["sources"] as? [String])?.isEmpty == true)
        try check(try Data(contentsOf: config) == original)
        try check(try request("aws.share", ["profileId": id, "targetName": "test"])["error"] != nil)
        try check(try Data(contentsOf: config) == original)
        let shared = try request("aws.share", ["profileId": id, "targetName": "test", "replaceSource": true])
        try check(shared["error"] == nil)
        try check((shared["installed"] as? [[String: Any]])?.count == 1)
        let deadline = Date().addingTimeInterval(10)
        var ready = false
        while !ready && Date() < deadline {
            let state = try request("aws.catalog")
            ready = (state["accounts"] as? [[String: Any]])?.first?["available"] as? Bool == true
            if !ready { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        }
        try check(ready)
        try check(try request("aws.credentials", ["profileId": id])["credentials"] is [String: Any])
        // Sign In supersedes an in-flight automatic renewal. A stale renewing
        // marker must not prevent the newly authenticated export from running.
        try Data("renewed".utf8).write(to: root.appendingPathComponent("generation"))
        try Data().write(to: root.appendingPathComponent("export-delay"))
        try check(try request("aws.refresh", ["profileId": id])["accepted"] as? Bool == true)
        let exportDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("export-started").path) && Date() < exportDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        try check(FileManager.default.fileExists(atPath: root.appendingPathComponent("export-started").path))
        try FileManager.default.removeItem(at: root.appendingPathComponent("export-delay"))
        try check(try request("aws.signIn.start", ["profileId": id])["accepted"] as? Bool == true)
        let renewedDeadline = Date().addingTimeInterval(5)
        var renewed = false
        while !renewed && Date() < renewedDeadline {
            let response = try request("aws.credentials", ["profileId": id])
            renewed = (response["credentials"] as? [String: Any])?["AccessKeyId"] as? String == "tdb-test-access-key-renewed"
            if !renewed { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        }
        try check(renewed)
        try Data().write(to: root.appendingPathComponent("signin-delay"))
        try check(try request("aws.signIn.start", ["profileId": id])["accepted"] as? Bool == true)
        let signInDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("signin-started").path) && Date() < signInDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        try check(FileManager.default.fileExists(atPath: root.appendingPathComponent("signin-started").path))
        try check(try request("aws.signIn.cancel")["accepted"] as? Bool == true)
        let cancelledSource = try request("aws.catalog")
        try check((cancelledSource["installed"] as? [[String: Any]])?.first?["source"] as? Bool == true)
        try check(try request("aws.signIn.start", ["profileId": id])["accepted"] as? Bool == true)
        try check(try request("aws.remove", ["profileId": id])["error"] == nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.9))
        try check(try Data(contentsOf: config) == original)
        try check(try request("aws.credentials", ["profileId": id])["error"] != nil)
        let afterRemoval = try request("aws.catalog")
        try check((afterRemoval["accounts"] as? [[String: Any]])?.isEmpty == true)
        try check(afterRemoval["phase"] as? String == "")

        // A receiving profile remains manageable after the originating Mac
        // withdraws it, even though no credential catalog entry remains.
        let otherProfile = AWSProfileDescriptor(name: "Other", kind: "sso", region: "us-east-1", ssoStartURL: "https://other.awsapps.com/start", ssoRegion: "us-east-1", accountID: "123456789012", roleName: "ReadOnly")
        let origin = SharedAWSStore(root: root.appendingPathComponent("other-source"))
        let local = SharedAWSStore(root: root)
        let credentials = AWSRoleCredentials(accessKeyId: "tdb-test-other-access", secretAccessKey: "tdb-test-other-secret", sessionToken: "tdb-test-other-session", expiration: Date().addingTimeInterval(600).timeIntervalSince1970)
        _ = try origin.publish(profile: otherProfile, principalARN: "arn:aws:sts::123456789012:assumed-role/AWSReservedSSO_ReadOnly_0123456789abcdef/synthetic", credentials: credentials, sourceName: "Synthetic source")
        try local.importBundle(origin.exportBundle())
        try check(try request("aws.use", ["profileId": otherProfile.id, "targetName": "received"])["error"] == nil)
        let receiverConfig = try Data(contentsOf: config)
        try check(try request("aws.source.enable", ["profileId": otherProfile.id])["error"] != nil)
        try check(try Data(contentsOf: config) == receiverConfig)
        try? FileManager.default.removeItem(at: root.appendingPathComponent("signin-started"))
        try check(try request("aws.signIn.start", ["profileId": otherProfile.id])["accepted"] as? Bool == true)
        let receiverSignInDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("signin-started").path) && Date() < receiverSignInDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        try check(FileManager.default.fileExists(atPath: root.appendingPathComponent("signin-started").path))
        try check(try request("aws.signIn.cancel")["accepted"] as? Bool == true)
        let cancelledReceiver = try request("aws.catalog")
        try check((cancelledReceiver["installed"] as? [[String: Any]])?.first?["source"] as? Bool == false)
        let localSourceData = try Data(contentsOf: root.appendingPathComponent("aws-service.json"))
        try check(try JSONDecoder().decode(SharedAWSLocalDocument.self, from: localSourceData).sources[otherProfile.id] == nil)
        service.start()
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        let afterCancel = try request("aws.catalog")
        try check((afterCancel["accounts"] as? [[String: Any]])?.first?["local"] as? Bool == false)
        try check(afterCancel["signInProfile"] as? String == "")
        try check(try request("aws.share", ["profileId": otherProfile.id, "targetName": "should-not-install"])["error"] != nil)
        try check(try Data(contentsOf: config) == receiverConfig)
        try origin.withdraw(otherProfile.id); try local.importBundle(origin.exportBundle())
        let withdrawn = try request("aws.catalog")
        try check((withdrawn["accounts"] as? [[String: Any]])?.isEmpty == true)
        try check((withdrawn["installed"] as? [[String: Any]])?.first?["descriptor"] is [String: Any])
        try check(try request("aws.remove", ["profileId": otherProfile.id])["error"] == nil)
        try check(try Data(contentsOf: config) == original)

        // Same-identity aliases can use different local SSO token caches. A
        // new explicit sign-in/share choice must drive the following export,
        // even when this persistent profile ID was already a local source.
        let aliasRoot = root.appendingPathComponent("alias-cache")
        try FileManager.default.createDirectory(at: aliasRoot.appendingPathComponent("aws-fixture"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let aliasCLI = aliasRoot.appendingPathComponent("aws")
        try FileManager.default.copyItem(at: fake, to: aliasCLI)
        setenv("TERMINALDB_AWS_QA_EXECUTABLE", aliasCLI.path, 1)
        try Data().write(to: aliasRoot.appendingPathComponent("capture-config"))
        let aliasConfig = aliasRoot.appendingPathComponent("aws-fixture/config")
        func aliasSection(_ name: String, session: String) -> String {
            "[profile \(name)]\nsso_session = \(session)\nsso_account_id = 123456789012\nsso_role_name = ReadOnly\n\n[sso-session \(session)]\nsso_start_url = https://example.awsapps.com/start\nsso_region = us-east-1\n\n"
        }
        var nativeAliases = aliasSection("z-original", session: "cache-original")
        try Data(nativeAliases.utf8).write(to: aliasConfig)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: aliasConfig.path)
        let aliasService = SharedAWSService(root: aliasRoot)
        func aliasRequest(_ operation: String, _ payload: [String: Any] = [:]) throws -> [String: Any] {
            var response: [String: Any]?
            aliasService.handle(operation, payload: payload) { response = $0 }
            let deadline = Date().addingTimeInterval(10)
            while response == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            guard let response else { throw PeerFailure("The synthetic AWS alias operation did not finish.") }
            return response
        }
        let aliasDescriptor = (try aliasRequest("aws.catalog")["profiles"] as! [[String: Any]])[0]
        let aliasID = aliasDescriptor["id"] as! String
        func lastCall(_ operation: String) throws -> [String: Any]? {
            let path = aliasRoot.appendingPathComponent("fixture-calls.jsonl")
            guard FileManager.default.fileExists(atPath: path.path) else { return nil }
            return try String(contentsOf: path, encoding: .utf8).split(separator: "\n").compactMap { line in
                let value = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
                return value?["operation"] as? String == operation ? value : nil
            }.last
        }
        func waitReady(_ name: String, session: String) throws -> Bool {
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                let state = try aliasRequest("aws.catalog")
                if state["signInProfile"] as? String == "", (state["sourceStatus"] as? [String: String])?[aliasID] == "Ready to share",
                   let call = try lastCall("configure"), call["profile"] as? String == name,
                   (call["config"] as? String)?.contains("sso_session = " + session + "\n") == true { return true }
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            return false
        }
        try check(try aliasRequest("aws.source.enable", ["profileId": aliasID])["error"] == nil)
        try check(try waitReady("z-original", session: "cache-original"))
        nativeAliases += aliasSection("a-current", session: "cache-current")
        try Data(nativeAliases.utf8).write(to: aliasConfig)
        try check(try aliasRequest("aws.signIn.start", ["profileId": aliasID])["accepted"] as? Bool == true)
        try check(try waitReady("a-current", session: "cache-current"))
        let signedInCall = try lastCall("sso")
        try check(signedInCall?["session"] as? String == "cache-current" && (signedInCall?["config"] as? String)?.contains("sso_session = cache-current\n") == true)
        let sourcePath = aliasRoot.appendingPathComponent("aws-service.json")
        func selectedAlias() throws -> String? { try JSONDecoder().decode(SharedAWSLocalDocument.self, from: Data(contentsOf: sourcePath)).sources[aliasID]?.descriptor.name }
        try check(try selectedAlias() == "a-current")

        // Switching a current source also fences an older in-flight export.
        try Data().write(to: aliasRoot.appendingPathComponent("export-delay"))
        try check(try aliasRequest("aws.refresh", ["profileId": aliasID])["accepted"] as? Bool == true)
        let stalledDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: aliasRoot.appendingPathComponent("export-started").path) && Date() < stalledDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        try check(FileManager.default.fileExists(atPath: aliasRoot.appendingPathComponent("export-started").path))
        nativeAliases += aliasSection("0-shared", session: "cache-shared")
        try Data(nativeAliases.utf8).write(to: aliasConfig)
        try FileManager.default.removeItem(at: aliasRoot.appendingPathComponent("export-delay"))
        try check(try aliasRequest("aws.source.enable", ["profileId": aliasID])["error"] == nil)
        try check(try waitReady("0-shared", session: "cache-shared"))
        try check(try selectedAlias() == "0-shared")

        // A failed metadata save must preserve the old source selection in
        // memory as well as on disk, without running the new alias export.
        nativeAliases += aliasSection("0-before", session: "cache-unsaved")
        try Data(nativeAliases.utf8).write(to: aliasConfig)
        try check((try aliasRequest("aws.catalog")["profiles"] as? [[String: Any]])?.first?["name"] as? String == "0-before")
        let previousSource = try Data(contentsOf: sourcePath)
        try FileManager.default.removeItem(at: sourcePath)
        try FileManager.default.createDirectory(at: sourcePath, withIntermediateDirectories: false)
        try check(try aliasRequest("aws.source.enable", ["profileId": aliasID])["error"] != nil)
        try FileManager.default.removeItem(at: sourcePath)
        try previousSource.write(to: sourcePath)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sourcePath.path)
        try check(try aliasRequest("aws.refresh", ["profileId": aliasID])["accepted"] as? Bool == true)
        try check(try waitReady("0-shared", session: "cache-shared"))
        try check(try selectedAlias() == "0-shared")
        try check(try Data(contentsOf: aliasConfig) == Data(nativeAliases.utf8))

        // Removal restores all safe aliases even if one was edited outside
        // TerminalDB. The conflicted recovery record and user edits survive.
        try check(try aliasRequest("aws.use", ["profileId": aliasID, "targetName": "mapped-one"])["error"] == nil)
        try check(try aliasRequest("aws.use", ["profileId": aliasID, "targetName": "mapped-two"])["error"] == nil)
        let beforeEdit = try String(contentsOf: aliasConfig, encoding: .utf8)
        let edited = beforeEdit.replacingOccurrences(of: "[profile mapped-one]\n", with: "[profile mapped-one]\n# Edited outside TerminalDB\n")
        try Data(edited.utf8).write(to: aliasConfig)
        let partialRemoval = try aliasRequest("aws.remove", ["profileId": aliasID])
        try check(partialRemoval["error"] != nil)
        let afterPartial = try String(contentsOf: aliasConfig, encoding: .utf8)
        try check(afterPartial.contains("# Edited outside TerminalDB") && afterPartial.contains("[profile mapped-one]"))
        try check(!afterPartial.contains("[profile mapped-two]"))
        let partialCatalog = try aliasRequest("aws.catalog")
        try check((partialCatalog["sources"] as? [String])?.isEmpty == true)
        try check((partialCatalog["sourceStatus"] as? [String: String])?[aliasID] == nil)
        try check((partialCatalog["installed"] as? [[String: Any]])?.count == 1)
        try Data(afterPartial.replacingOccurrences(of: "# Edited outside TerminalDB\n", with: "").utf8).write(to: aliasConfig)
        try check(try aliasRequest("aws.remove", ["profileId": aliasID])["error"] == nil)
        try check(try Data(contentsOf: aliasConfig) == Data(nativeAliases.utf8))
        // A browser login renews one named SSO session across account/role
        // profiles, while credential publication stays explicitly selected.
        let sessionRoot = root.appendingPathComponent("shared-session")
        try FileManager.default.createDirectory(at: sessionRoot.appendingPathComponent("aws-fixture"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let sessionCLI = sessionRoot.appendingPathComponent("aws")
        try FileManager.default.copyItem(at: fake, to: sessionCLI)
        setenv("TERMINALDB_AWS_QA_EXECUTABLE", sessionCLI.path, 1)
        try Data().write(to: sessionRoot.appendingPathComponent("capture-config"))
        func sessionProfile(_ name: String, role: String, session: String = "team") -> String {
            "[profile \(name)]\nsso_session = \(session)\nsso_account_id = 123456789012\nsso_role_name = \(role)\nregion = us-east-1\n\n"
        }
        let sessionConfig = sessionRoot.appendingPathComponent("aws-fixture/config")
        let sessionBytes = Data((sessionProfile("alpha", role: "ReadOnly") + sessionProfile("beta", role: "Developer") + sessionProfile("unshared", role: "Analyst") + sessionProfile("other", role: "Audit", session: "other-team") +
            "[sso-session team]\nsso_start_url = https://example.awsapps.com/start\nsso_region = us-east-1\n\n[sso-session other-team]\nsso_start_url = https://example.awsapps.com/start\nsso_region = us-east-1\n").utf8)
        try sessionBytes.write(to: sessionConfig)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sessionConfig.path)
        let cache = sessionRoot.appendingPathComponent(".aws/sso/cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // SHA-1 filenames are AWS CLI's documented cache convention. These are
        // disposable metadata fixtures; no real token is read or generated.
        func expiredSession(_ name: String) throws {
            let command = Process(); command.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            command.arguments = ["-c", "import pathlib,hashlib,json,sys; p=pathlib.Path(sys.argv[1])/(hashlib.sha1(sys.argv[2].encode()).hexdigest()+'.json'); p.write_text(json.dumps({'accessToken':'tdb-test-expired-token','startUrl':'https://example.awsapps.com/start','region':'us-east-1','expiresAt':'2020-01-01T00:00:00Z'})); p.chmod(0o600)", cache.path, name]
            command.standardInput = FileHandle.nullDevice; command.standardOutput = FileHandle.nullDevice; command.standardError = FileHandle.nullDevice
            try command.run(); command.waitUntilExit()
            guard command.terminationStatus == 0 else { throw PeerFailure("The synthetic SSO cache could not be prepared.") }
        }
        try expiredSession("team"); try expiredSession("other-team")
        let sessionService = SharedAWSService(root: sessionRoot)
        func sessionRequest(_ operation: String, _ payload: [String: Any] = [:]) throws -> [String: Any] {
            var response: [String: Any]?
            sessionService.handle(operation, payload: payload) { response = $0 }
            let deadline = Date().addingTimeInterval(10)
            while response == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            guard let response else { throw PeerFailure("The synthetic shared SSO operation did not finish.") }
            return response
        }
        let discovered = try sessionRequest("aws.catalog")["profiles"] as! [[String: Any]]
        let ids = Dictionary(uniqueKeysWithValues: discovered.map { ($0["name"] as! String, $0["id"] as! String) })
        let alpha = ids["alpha"]!, beta = ids["beta"]!, unshared = ids["unshared"]!, other = ids["other"]!
        func authState(_ catalog: [String: Any], _ id: String) -> String? {
            (catalog["authentication"] as? [String: [String: Any]])?[id]?["state"] as? String
        }
        func waitSessionReady(_ expected: String, _ expectedSources: [String]) throws -> Bool {
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                let state = try sessionRequest("aws.catalog")
                let statuses = state["sourceStatus"] as? [String: String] ?? [:]
                if state["signInProfile"] as? String == "", expectedSources.allSatisfy({ statuses[$0] == "Ready to share" }) {
                    var matches = true
                    for id in expectedSources {
                        let value = try sessionRequest("aws.credentials", ["profileId": id])
                        if (value["credentials"] as? [String: Any])?["AccessKeyId"] as? String != expected { matches = false }
                    }
                    if matches { return true }
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            return false
        }
        for id in [alpha, beta, other] { try check(try sessionRequest("aws.source.enable", ["profileId": id])["error"] == nil) }
        try check(try waitSessionReady("tdb-test-access-key", [alpha, beta, other]))
        let cachedButExpired = try sessionRequest("aws.catalog")
        try check(authState(cachedButExpired, alpha) == "expired" && authState(cachedButExpired, beta) == "expired")
        try check((cachedButExpired["accounts"] as? [[String: Any]])?.filter { $0["available"] as? Bool == true }.count == 3)
        try Data("session-renewed".utf8).write(to: sessionRoot.appendingPathComponent("generation"))
        try Data().write(to: sessionRoot.appendingPathComponent("signin-delay"))
        try check(try sessionRequest("aws.signIn.start", ["profileId": alpha])["accepted"] as? Bool == true)
        let signingIn = try sessionRequest("aws.catalog")
        try check(Set(signingIn["signInProfiles"] as? [String] ?? []) == Set([alpha, beta, unshared]))
        try check(try sessionRequest("aws.source.enable", ["profileId": unshared])["error"] != nil)
        try check(try waitSessionReady("tdb-test-access-key-session-renewed", [alpha, beta]))
        let signedIn = try sessionRequest("aws.catalog")
        try check(authState(signedIn, alpha) == "current" && authState(signedIn, beta) == "current" && authState(signedIn, unshared) == "current")
        try check(authState(signedIn, other) == "expired")
        try check(Set(signedIn["sources"] as? [String] ?? []) == Set([alpha, beta, other]))
        let unrelated = try sessionRequest("aws.credentials", ["profileId": other])
        try check((unrelated["credentials"] as? [String: Any])?["AccessKeyId"] as? String == "tdb-test-access-key")
        let sessionCalls = try String(contentsOf: sessionRoot.appendingPathComponent("fixture-calls.jsonl"), encoding: .utf8).split(separator: "\n").compactMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        try check(sessionCalls.filter { $0["operation"] as? String == "sso" }.count == 1)
        try check(sessionCalls.first { $0["operation"] as? String == "sso" }?["session"] as? String == "team")
        try check(try Data(contentsOf: sessionConfig) == sessionBytes)
        // Cancellation and failure retain cached access but never turn an
        // expired shared SSO login into a successful authentication state.
        try expiredSession("team")
        try check(try sessionRequest("aws.signIn.start", ["profileId": beta])["accepted"] as? Bool == true)
        try check(try sessionRequest("aws.signIn.cancel")["accepted"] as? Bool == true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.9))
        let cancelledSession = try sessionRequest("aws.catalog")
        try check(cancelledSession["signInProfile"] as? String == "" && authState(cancelledSession, alpha) == "expired")
        try check((try sessionRequest("aws.credentials", ["profileId": alpha])["credentials"] as? [String: Any])?["AccessKeyId"] as? String == "tdb-test-access-key-session-renewed")
        try Data().write(to: sessionRoot.appendingPathComponent("signin-fail"))
        try check(try sessionRequest("aws.signIn.start", ["profileId": alpha])["accepted"] as? Bool == true)
        let failedDeadline = Date().addingTimeInterval(5)
        var failedSession: [String: Any] = [:]
        repeat {
            failedSession = try sessionRequest("aws.catalog")
            if failedSession["signInProfile"] as? String == "" { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        } while Date() < failedDeadline
        try check(failedSession["signInProfile"] as? String == "" && authState(failedSession, beta) == "expired")
        try check((try sessionRequest("aws.credentials", ["profileId": beta])["credentials"] as? [String: Any])?["AccessKeyId"] as? String == "tdb-test-access-key-session-renewed")
        try check(Set(failedSession["sources"] as? [String] ?? []) == Set([alpha, beta, other]))
        try FileManager.default.removeItem(at: sessionRoot.appendingPathComponent("signin-fail"))
        try check(try sessionRequest("aws.signIn.start", ["profileId": alpha])["accepted"] as? Bool == true)
        try check(try sessionRequest("aws.signIn.cancel")["accepted"] as? Bool == true)
        try check(try sessionRequest("aws.signIn.start", ["profileId": beta])["accepted"] as? Bool == true)
        try check(try waitSessionReady("tdb-test-access-key-session-renewed", [alpha, beta]))
        try check(authState(try sessionRequest("aws.catalog"), alpha) == "current")
        try check(try Data(contentsOf: sessionConfig) == sessionBytes)
        return count
    }
}
