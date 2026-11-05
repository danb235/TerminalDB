import Foundation
import Darwin

// AWS CLI output is private protocol data. It is never forwarded to terminal
// renderers, UI errors, telemetry, command history or log streams.
private final class SharedAWSCommand {
    private let queue: DispatchQueue
    private let task = Process()
    private var reader: DispatchSourceRead?
    private var errorReader: DispatchSourceRead?
    private var deadline: DispatchSourceTimer?
    private var output = Data()
    private var errorOutput = Data()
    private var descriptor: Int32 = -1
    private var errorDescriptor: Int32 = -1
    private var completed = false
    private var callback: ((Result<Data, Error>) -> Void)?
    private var pipe: Pipe?
    private var errorPipe: Pipe?
    private let maximumOutput = 65_536
    private let maximumErrorOutput = 16_384

    init(queue: DispatchQueue) { self.queue = queue }

    func start(executable: URL, arguments: [String], environment: [String: String],
               timeout: Double, capture: Bool,
               completion: @escaping (Result<Data, Error>) -> Void) throws {
        callback = completion
        task.executableURL = executable; task.arguments = arguments
        task.environment = environment
        task.standardInput = FileHandle.nullDevice
        let errors = Pipe(); errorPipe = errors
        errorDescriptor = errors.fileHandleForReading.fileDescriptor
        guard fcntl(errorDescriptor, F_SETFL, fcntl(errorDescriptor, F_GETFL) | O_NONBLOCK) == 0 else {
            callback = nil; finish(.failure(SharedAWSCommandFailure(state: .checkFailed)))
            throw SharedAWSCommandFailure(state: .checkFailed)
        }
        task.standardError = errors
        let errorSource = DispatchSource.makeReadSource(fileDescriptor: errorDescriptor, queue: queue)
        errorSource.setEventHandler { [weak self] in self?.drainErrors() }
        errorReader = errorSource; errorSource.resume()
        if capture {
            let channel = Pipe(); pipe = channel
            descriptor = channel.fileHandleForReading.fileDescriptor
            guard fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) == 0 else {
                callback = nil; finish(.failure(SharedAWSCommandFailure(state: .checkFailed)))
                throw SharedAWSCommandFailure(state: .checkFailed)
            }
            task.standardOutput = channel
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.drain() }
            reader = source; source.resume()
        } else { task.standardOutput = FileHandle.nullDevice }
        task.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.drain(); self.drainErrors()
                guard !self.completed else { return }
                if self.task.terminationStatus == 0 { self.finish(.success(self.output)) }
                else { self.finish(.failure(SharedAWSCommandFailure.classify(self.errorOutput))) }
            }
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in
            self?.finish(.failure(SharedAWSCommandFailure(state: .networkUnavailable)))
        }
        deadline = timer; timer.resume()
        do { try task.run() }
        catch { callback = nil; finish(.failure(SharedAWSCommandFailure(state: .checkFailed))); throw SharedAWSCommandFailure(state: .checkFailed) }
    }

    private func drain() {
        guard descriptor >= 0, !completed else { return }
        var bytes = [UInt8](repeating: 0, count: 4096)
        defer { bytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        for _ in 0..<32 {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            guard count > 0 else { break }
            guard output.count + count <= maximumOutput else {
                finish(.failure(SharedAWSCommandFailure(state: .checkFailed))); return
            }
            output.append(contentsOf: bytes.prefix(count))
        }
    }

    private func drainErrors() {
        guard errorDescriptor >= 0, !completed else { return }
        var bytes = [UInt8](repeating: 0, count: 4096)
        defer { bytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        for _ in 0..<32 {
            let count = Darwin.read(errorDescriptor, &bytes, bytes.count)
            guard count > 0 else { break }
            guard errorOutput.count + count <= maximumErrorOutput else {
                finish(.failure(SharedAWSCommandFailure(state: .checkFailed))); return
            }
            errorOutput.append(contentsOf: bytes.prefix(count))
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        guard !completed else { return }; completed = true
        deadline?.cancel(); deadline = nil
        reader?.cancel(); reader = nil; descriptor = -1
        errorReader?.cancel(); errorReader = nil; errorDescriptor = -1
        try? pipe?.fileHandleForReading.close(); try? pipe?.fileHandleForWriting.close(); pipe = nil
        try? errorPipe?.fileHandleForReading.close(); try? errorPipe?.fileHandleForWriting.close(); errorPipe = nil
        if task.isRunning {
            task.terminate()
            let process = task
            queue.asyncAfter(deadline: .now() + 2) {
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            }
        }
        output.resetBytes(in: 0..<output.count); output.removeAll()
        errorOutput.resetBytes(in: 0..<errorOutput.count); errorOutput.removeAll()
        let completion = callback; callback = nil; completion?(result)
    }
    func cancel() { finish(.failure(SharedAWSCommandFailure(state: .checkFailed))) }
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
    private var signInAttempt: String?
    private var signInSessionKey: String?
    private var signInRenewalGeneration: UInt64 = 0
    private var phase = ""
    private var sourceStatus: [String: String] = [:]
    private var sourceChecks: [String: SharedAWSAccessCheck] = [:]
    private let statusCache = SharedAWSStatusCache()
    private let statusWatchQueue = DispatchQueue(label: "com.terminaldb.aws-status-watch")
    private var statusWatchTimer: DispatchSourceTimer?
    private var watchedMetadata: [String: String]?
    private var statusRefreshScheduled = false
    private var lastStatusRefresh: Double = 0
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
            timer.setEventHandler { [weak self] in self?.refreshEligible(); self?.scheduleStatusRefresh() }
            self.refreshTimer = timer; timer.resume()
        }
        statusWatchQueue.async {
            guard self.statusWatchTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.statusWatchQueue)
            timer.schedule(deadline: .now(), repeating: 5)
            timer.setEventHandler { [weak self] in self?.watchStatusMetadata() }
            self.statusWatchTimer = timer; timer.resume()
        }
    }
    deinit { refreshTimer?.cancel(); statusWatchTimer?.cancel() }

    func status() -> [String: Any] { statusCache.envelope() }

    func handle(_ operation: String, payload: [String: Any], audit: Data? = nil, authenticate: Bool = false,
                queuedAuthorization: (() -> Bool)? = nil,
                completion: @escaping ([String: Any]) -> Void) {
        if operation == "aws.status" { completion(status()); return }
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
                guard queuedAuthorization?() != false else {
                    reply(["error": "This view no longer controls the session. Choose Take Control.", "code": "control-required"])
                    return
                }
                try self.load()
                if self.signInProfile == nil && ["aws.source.enable", "aws.share", "aws.use", "aws.remove", "aws.refresh"].contains(operation) {
                    self.phase = ""
                }
                switch operation {
                case "aws.catalog": reply(try self.snapshotCatalog())
                case "aws.check":
                    let profile = try self.profile(payload)
                    let receiving = try self.configuration.installations().contains(where: { $0.descriptor.id == profile.id })
                    let configured = try self.configuration.discover().contains(where: { $0 == profile })
                    guard self.document.sources[profile.id] == nil,
                          receiving || configured else {
                        throw PeerFailure("Check a local AWS profile, or use the shared profile's access controls.")
                    }
                    let manual = payload["manual"] as? Bool == true
                    let accepted = self.checkLocal(profile, manual: manual, receiving: receiving)
                    if manual && !accepted { throw PeerFailure("AWS is checking other profiles. Try Check Access again in a moment.") }
                    reply(["accepted": accepted])
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
                    self.notify(); reply(try self.snapshotCatalog())
                case "aws.share", "aws.use":
                    let profile = try self.profile(payload)
                    let target = payload["targetName"] as? String ?? profile.name
                    let stopSource = operation == "aws.use" && payload["stopSource"] as? Bool == true
                    if stopSource {
                        guard payload["replaceSource"] as? Bool == true, self.document.sources[profile.id] != nil,
                              !self.isSigningIn(profile) else { throw PeerFailure("Confirm switching this local source to shared AWS access first.") }
                        guard try self.store.hasIncomingCredentials(forProfile: profile.id) else {
                            throw PeerFailure("Shared access is unavailable. Reconnect a providing Mac before switching this profile.")
                        }
                    }
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
                    guard queuedAuthorization?() != false else {
                        reply(["error": "This view no longer controls the session. Choose Take Control.", "code": "control-required"]); return
                    }
                    let installation = try self.configuration.install(profile, targetName: target, launcherPath: TDBSharedAWS.launcherPath,
                                                                      allowReplacingSource: payload["replaceSource"] as? Bool == true)
                    if stopSource {
                        let previousSource = self.document.sources[profile.id]
                        do {
                            guard try self.store.hasIncomingCredentials(forProfile: profile.id) else { throw PeerFailure("The shared access changed before this profile could switch.") }
                            guard queuedAuthorization?() != false else {
                                if previousInstallation == nil { try self.configuration.restore(installation) }
                                reply(["error": "This view no longer controls the session. Choose Take Control.", "code": "control-required"]); return
                            }
                            self.document.sources.removeValue(forKey: profile.id)
                            try self.save()
                            try self.store.withdraw(profile.id)
                        } catch {
                            self.document.sources[profile.id] = previousSource
                            try? self.save()
                            if previousInstallation == nil { try? self.configuration.restore(installation) }
                            throw PeerFailure("The switch to shared access did not finish. Check this profile in AWS Access before trying again.")
                        }
                        self.sourceStatus.removeValue(forKey: profile.id)
                    }
                    if operation == "aws.use" {
                        self.cancelRefresh(profile.id)
                        self.sourceChecks.removeValue(forKey: profile.id)
                    }
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
                    self.notify(); reply(try self.snapshotCatalog())
                case "aws.signIn.start":
                    guard self.signInProfile == nil else { throw PeerFailure("Complete or cancel the AWS sign-in already open in your browser.") }
                    let profile = try self.profile(payload, allowingSignInDescriptor: true)
                    guard self.document.sources[profile.id] != nil || self.document.sources.count < Self.maximumLocalSources else {
                        throw PeerFailure("Share up to 16 AWS profiles from this Mac. Stop sharing one before adding another.")
                    }
                    // One browser sign-in owns the SSO session, not just its
                    // selected account/role. Fence every related renewal before
                    // authentication so old exports cannot overwrite new access.
                    let sessionKey = try self.sessionKey(for: profile)
                    self.signInRenewalGeneration &+= 1
                    let renewalGeneration = self.signInRenewalGeneration
                    for candidate in try self.localProfiles() where candidate.id == profile.id || (sessionKey != nil && (try? self.sessionKey(for: candidate)) == sessionKey) {
                        self.cancelRefresh(candidate.id)
                        // Browser progress is separate from credential proof.
                        // Retain prior verified access and confirmed failures
                        // until successful authentication or a real new check.
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
                    let attempt = UUID().uuidString
                    self.jobs[key] = command; self.signInProfile = profile.id; self.signInAttempt = attempt; self.signInSessionKey = sessionKey
                    self.phase = profile.kind == "sso" ? "Complete AWS sign-in in your browser. This signs in all profiles using this SSO session on this Mac." : "Complete AWS sign-in in your browser on this Mac."
                    self.notify()
                    var launched = false
                    defer {
                        if !launched {
                            self.jobs.removeValue(forKey: key); self.signInProfile = nil; self.signInAttempt = nil; self.signInSessionKey = nil
                            command.cancel()
                        }
                    }
                    try command.start(executable: executable, arguments: try self.configuration.loginArguments(for: profile),
                                      environment: environment, timeout: 600, capture: false) { [weak self, weak command] result in
                        guard let self, let command, self.jobs[key] === command else { return }
                        self.jobs.removeValue(forKey: key); self.signInProfile = nil; self.signInAttempt = nil; self.signInSessionKey = nil
                        switch result {
                        case .success:
                            do {
                                let authenticationState = profile.kind == "sso" ? self.configuration.authenticationStatus(for: profile)["state"] as? String : nil
                                if profile.kind != "sso" || authenticationState == "current" {
                                    if self.sourceChecks[profile.id]?.state == .signInRequired { self.sourceChecks.removeValue(forKey: profile.id) }
                                    for candidate in try self.localProfiles() where sessionKey != nil && (try? self.sessionKey(for: candidate)) == sessionKey {
                                        if self.sourceChecks[candidate.id]?.state == .signInRequired { self.sourceChecks.removeValue(forKey: candidate.id) }
                                    }
                                }
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
                                    let state = authenticationState
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
                    reply(["accepted": true, "signInAttempt": attempt])
                case "aws.signIn.cancel":
                    if let id = payload["profileId"] as? String {
                        guard Self.validID(id) else { throw PeerFailure("Choose the AWS sign-in to cancel.") }
                        guard let current = self.signInProfile else { reply(["accepted": true]); return }
                        guard id == current else { throw PeerFailure("A different AWS sign-in is running. Manage it from its own window.") }
                    }
                    if let attempt = payload["signInAttempt"] as? String {
                        guard UUID(uuidString: attempt) != nil else { throw PeerFailure("Choose the AWS sign-in to cancel.") }
                        guard self.signInProfile != nil else { reply(["accepted": true]); return }
                        guard attempt == self.signInAttempt else { throw PeerFailure("This AWS sign-in has changed. Manage the current sign-in from its own window.") }
                    }
                    self.cancelSignIn()
                    self.phase = "AWS sign-in cancelled. Existing cached profile access is kept until it expires."; self.notify(); reply(["accepted": true])
                case "aws.refresh":
                    if let id = payload["profileId"] as? String {
                        guard let source = self.document.sources[id] else { throw PeerFailure("Sign in on this Mac to renew this AWS profile.") }
                        guard !self.isSigningIn(source.descriptor) else { throw PeerFailure("Complete or cancel this AWS sign-in before checking access.") }
                        if self.renewing.contains(id) { reply(["accepted": true]); return }
                        guard self.jobs.count < 4 else { throw PeerFailure("AWS is checking other profiles. Try Check Access again in a moment.") }
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
                    self.sourceChecks.removeValue(forKey: profile.id)
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
                    self.notify(); reply(try self.snapshotCatalog())
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
        if let check = sourceChecks[id], check.state == .checking {
            // Cancelling a pending check must not leave a permanent spinner or
            // replace its own prior credential proof with a received expiry.
            if let expiry = check.expiresAt, expiry.isFinite, expiry > Date().timeIntervalSince1970 {
                sourceChecks[id] = SharedAWSAccessCheck(state: .ready, checkedAt: check.checkedAt, expiresAt: expiry)
                if document.sources[id] != nil { sourceStatus[id] = SharedAWSCheckState.ready.status }
            } else {
                sourceChecks.removeValue(forKey: id)
                sourceStatus.removeValue(forKey: id)
            }
        }
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
        signInProfile = nil; signInAttempt = nil; signInSessionKey = nil
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
    private func profile(_ payload: [String: Any], allowingSignInDescriptor: Bool = false) throws -> AWSProfileDescriptor {
        guard let id = payload["profileId"] as? String, Self.validID(id) else { throw PeerFailure("Choose an AWS profile first.") }
        if let result = try localProfiles().first(where: { $0.id == id }) { return result }
        if let result = try configuration.installations().first(where: { $0.descriptor.id == id }) { return result.descriptor }
        if let result = try store.profiles().first(where: { $0.id == id }) { return result }
        if allowingSignInDescriptor, let fields = payload["descriptor"] as? [String: Any],
           JSONSerialization.isValidJSONObject(fields) {
            let bytes = try JSONSerialization.data(withJSONObject: fields)
            guard bytes.count <= 16_384 else { throw PeerFailure("This AWS profile description is too large.") }
            let descriptor = try JSONDecoder().decode(AWSProfileDescriptor.self, from: bytes)
            try descriptor.validate()
            guard descriptor.id == id, descriptor.kind == "sso" else {
                throw PeerFailure("Choose a valid SSO profile to sign in on this Mac.")
            }
            return descriptor
        }
        throw PeerFailure("This AWS profile is no longer available. Reconnect the Mac that shared it.")
    }
    private func catalog() throws -> [String: Any] {
        let local = try localProfiles()
        pruneChecks(keeping: Set(local.map(\.id) + (try configuration.installations()).map { $0.descriptor.id }))
        let profiles = try local.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
        var authentication: [String: [String: Any]] = [:]
        for profile in local where authentication[profile.id] == nil { authentication[profile.id] = configuration.authenticationStatus(for: profile) }
        let installed: [[String: Any]] = try configuration.installations().map {
            ["profileId": $0.descriptor.id, "targetName": $0.targetName, "source": document.sources[$0.descriptor.id] != nil,
             "descriptor": try JSONSerialization.jsonObject(with: JSONEncoder().encode($0.descriptor))]
        }
        let accounts = try store.catalog()
        // Reuse the catalog's already-resolved metadata; never read another
        // credential copy merely to discard an obsolete check. A newly arrived
        // copy resolves prior unavailability, and a changed expiration belongs
        // to a different access result. Same-expiry permission failures stay.
        let receivers = Set(installed.compactMap { item -> String? in
            guard let id = item["profileId"] as? String, document.sources[id] == nil else { return nil }
            return id
        })
        for account in accounts where account["available"] as? Bool == true {
            guard let id = account["profileId"] as? String, receivers.contains(id),
                  let check = sourceChecks[id], let expiry = account["expires"] as? Double else { continue }
            if check.needsSharedRenewal || check.expiresAt.map({ abs($0 - expiry) > 0.001 }) == true {
                sourceChecks.removeValue(forKey: id)
            }
        }
        return ["profiles": profiles, "accounts": accounts, "installed": installed,
                "configuredProfileIDs": Array(Set(try configuration.discover().map(\.id))).sorted(),
                "localProfileNames": try configuration.configuredNames(),
                "phase": phase, "sourceStatus": sourceStatus, "signInProfile": signInProfile ?? "", "signInAttempt": signInAttempt ?? "",
                "signInProfiles": Array(Set(local.filter { isSigningIn($0) }.map(\.id))).sorted(),
                "authentication": authentication,
                "sourceChecks": sourceChecks.mapValues(\.metadata),
                "sources": document.sources.keys.sorted()]
    }
    private func snapshotCatalog() throws -> [String: Any] {
        let ticket = statusCache.ticket()
        do {
            let result = try catalog()
            _ = statusCache.replace(result, ticket: ticket)
            return result
        } catch { statusCache.unavailable(ticket: ticket); throw error }
    }
    private func scheduleStatusRefresh() {
        guard !statusRefreshScheduled else { return }
        statusRefreshScheduled = true
        let delay = max(0.1, 2 - (ProcessInfo.processInfo.systemUptime - lastStatusRefresh))
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.statusRefreshScheduled = false; self.lastStatusRefresh = ProcessInfo.processInfo.systemUptime
            do { try self.load(); _ = try self.snapshotCatalog() }
            catch { self.statusCache.unavailable(ticket: self.statusCache.ticket()) }
            DispatchQueue.main.async { self.changed?() }
        }
    }
    private func watchStatusMetadata() {
        let config = SharedAccountCodeIdentity.fixture ? root.appendingPathComponent("aws-fixture/config")
            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".aws/config")
        var metadata: [String: String] = [:]
        for path in [config, root.appendingPathComponent("aws-service.json"), root.appendingPathComponent("shared-aws.json")] {
            let attributes = try? FileManager.default.attributesOfItem(atPath: path.path)
            let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            metadata[path.path] = "\(attributes?[.systemFileNumber] ?? "missing"):\(attributes?[.size] ?? 0):\(modified)"
        }
        guard metadata != watchedMetadata else { return }
        watchedMetadata = metadata; statusCache.invalidate()
        queue.async { [weak self] in self?.scheduleStatusRefresh() }
    }
    private func notify() {
        statusCache.invalidate(); scheduleStatusRefresh()
        DispatchQueue.main.async { self.changed?() }
    }

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
        document.sources[id]?.lastAttempt = now
        try? save()
        performCheck(source.descriptor, publish: true, completion: completion)
    }
    // An ordinary local profile can be checked without enrolling it, creating
    // a provider mapping, publishing access, or starting a browser sign-in.
    // First-open callers reuse recent outcomes before consuming a CLI job slot.
    private func checkLocal(_ profile: AWSProfileDescriptor, manual: Bool, receiving: Bool = false) -> Bool {
        let now = Date().timeIntervalSince1970
        if !manual, let previous = sourceChecks[profile.id], previous.checkedAt <= now {
            let ttl: Double = previous.state == .ready ? 60 : 300
            if now - previous.checkedAt < ttl { return true }
        }
        if renewing.contains(profile.id) { return true }
        guard !isSigningIn(profile), jobs.count < 4 else { return false }
        if sourceChecks.count >= 256,
           let oldest = sourceChecks.filter({ document.sources[$0.key] == nil && !renewing.contains($0.key) }).min(by: { $0.value.checkedAt < $1.value.checkedAt })?.key {
            sourceChecks.removeValue(forKey: oldest)
        }
        if receiving { performReceiverCheck(profile) }
        else { performCheck(profile, publish: false) }
        return true
    }
    private func pruneChecks(keeping ids: Set<String>) {
        sourceChecks = sourceChecks.filter { ids.contains($0.key) || renewing.contains($0.key) }
    }
    private func performReceiverCheck(_ profile: AWSProfileDescriptor) {
        let id = profile.id
        renewing.insert(id)
        let knownExpiry = (try? store.catalog().first { $0["profileId"] as? String == id }?["expires"] as? Double) ?? sourceChecks[id]?.expiresAt
        sourceChecks[id] = SharedAWSAccessCheck(state: .checking, checkedAt: Date().timeIntervalSince1970, expiresAt: knownExpiry)
        notify()
        let credentials: AWSRoleCredentials
        do { credentials = try store.credentials(forProfile: id) }
        catch { finishRefresh(id, expiry: nil, needsSharedRenewal: true); return }
        do {
            let config = root.appendingPathComponent("aws-access-check.config")
            // This STS request uses only the received copy. It must never fall
            // through to a preserved native SSO profile or browser-login cache.
            try Data().write(to: config, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
            verifyAndPublish(profile, credentials: credentials, executable: try SharedAWSCLI.executable(root: root),
                             config: config, publish: false, receiving: true, completion: nil)
        } catch { finishRefresh(id, expiry: nil) }
    }
    private func performCheck(_ profile: AWSProfileDescriptor, publish: Bool, completion: (() -> Void)? = nil) {
        let id = profile.id
        renewing.insert(id)
        sourceChecks[id] = SharedAWSAccessCheck(state: .checking, checkedAt: Date().timeIntervalSince1970,
                                                expiresAt: sourceChecks[id]?.expiresAt)
        if publish { sourceStatus[id] = SharedAWSCheckState.checking.status }
        notify()
        do {
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
                    var data = try result.get()
                    defer { data.resetBytes(in: 0..<data.count) }
                    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PeerFailure("AWS returned an invalid credential response.") }
                    let credentials = try AWSRoleCredentials(process: value)
                    try credentials.validate(now: Date().timeIntervalSince1970, syntheticOnly: SharedAccountCodeIdentity.fixture)
                    self.verifyAndPublish(profile, credentials: credentials, executable: executable, config: config, publish: publish, completion: completion)
                } catch { self.finishRefresh(id, expiry: nil, failure: (error as? SharedAWSCommandFailure)?.state ?? .checkFailed); completion?() }
            }
        } catch { jobs.removeValue(forKey: "refresh:" + id); finishRefresh(id, expiry: nil, failure: (error as? SharedAWSCommandFailure)?.state ?? .checkFailed); completion?() }
    }
    private func verifyAndPublish(_ profile: AWSProfileDescriptor, credentials: AWSRoleCredentials, executable: URL,
                                  config: URL, publish: Bool, receiving: Bool = false, completion: (() -> Void)?) {
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
                    if publish {
                        guard self.document.sources[profile.id]?.descriptor == profile else { throw PeerFailure("The AWS source selection changed.") }
                    } else if receiving {
                        guard self.document.sources[profile.id] == nil,
                              try self.configuration.installations().contains(where: { $0.descriptor.id == profile.id }) else {
                            throw PeerFailure("The receiving AWS profile changed.")
                        }
                    } else {
                        guard self.document.sources[profile.id] == nil,
                              try self.configuration.discover().contains(where: { $0 == profile }),
                              try !self.configuration.installations().contains(where: { $0.descriptor.id == profile.id }) else {
                            throw PeerFailure("The local AWS profile changed.")
                        }
                    }
                    var data = try result.get()
                    defer { data.resetBytes(in: 0..<data.count) }
                    guard let identity = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PeerFailure("AWS returned an invalid account identity.") }
                    let arn = try SharedAWSPrincipal.verify(identity, profile: profile)
                    if publish {
                        _ = try self.store.publish(profile: profile, principalARN: arn, credentials: credentials,
                                                   sourceName: PeerProtocol.displayName(Host.current().localizedName ?? "This Mac"))
                    }
                    self.finishRefresh(profile.id, expiry: credentials.expiration)
                } catch {
                    let outcome = (error as? SharedAWSCommandFailure)?.state ?? .checkFailed
                    self.finishRefresh(profile.id, expiry: nil, failure: receiving && outcome == .signInRequired ? .checkFailed : outcome)
                }
                completion?()
            }
        } catch { jobs.removeValue(forKey: "refresh:" + profile.id); finishRefresh(profile.id, expiry: nil, failure: (error as? SharedAWSCommandFailure)?.state ?? .checkFailed); completion?() }
    }
    private func finishRefresh(_ id: String, expiry: Double?, failure: SharedAWSCheckState = .checkFailed,
                               needsSharedRenewal: Bool = false) {
        renewing.remove(id)
        let state: SharedAWSCheckState = expiry == nil ? failure : .ready
        sourceChecks[id] = SharedAWSAccessCheck(state: state, checkedAt: Date().timeIntervalSince1970,
                                                expiresAt: expiry ?? sourceChecks[id]?.expiresAt,
                                                needsSharedRenewal: needsSharedRenewal)
        guard document.sources[id] != nil else { notify(); return }
        document.sources[id]?.failed = expiry == nil
        if let expiry { document.sources[id]?.lastExpiry = expiry }
        sourceStatus[id] = state.status
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
        var checks = try SharedAWSChecksTests.run() + AWSStatusTests.run()
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
        func process(_ script: String, timeout: Double = 3, expectSuccess: Bool,
                     failureState: SharedAWSCheckState = .checkFailed) throws -> Bool {
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
                        case .failure(let error): result.succeeded = !expectSuccess && (error as? SharedAWSCommandFailure)?.state == failureState
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
        try check(try process("/bin/sleep 2", timeout: 0.05, expectSuccess: false, failureState: .networkUnavailable))
        try check(try process("printf '%s' \"Your session has expired or credentials have changed. Please reauthenticate using 'aws login'.\" >&2; exit 1", expectSuccess: false, failureState: .signInRequired))
        try check(try process("printf '%s' 'Could not connect to the endpoint URL: synthetic' >&2; exit 1", expectSuccess: false, failureState: .networkUnavailable))
        try check(try process("printf '%s' 'AccessDeniedException' >&2; exit 1", expectSuccess: false, failureState: .accessDenied))
        try check(try process("/usr/bin/yes synthetic | /usr/bin/head -c 20000 >&2; exit 1", expectSuccess: false))
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
        mode=(Path(os.environ['HOME'])/'check-failure').read_text().strip() if (Path(os.environ['HOME'])/'check-failure').exists() else ''
        if args[:2]==['configure','export-credentials']:
            messages={
                'auth': 'The SSO session associated with this profile has expired or is otherwise invalid. To refresh this SSO session run aws sso login with the corresponding profile.',
                'network': 'Token has expired and refresh failed: Could not connect to the endpoint URL: synthetic',
                'denied': 'An error occurred (AccessDeniedException) when calling GetRoleCredentials',
                'config': 'Synthetic configuration is unavailable; tdb-test-private-diagnostic'
            }
            if mode in messages:
                print(messages[mode],file=sys.stderr);sys.exit(1)
        if (Path(os.environ['HOME'])/'capture-config').exists():
            profile=args[args.index('--profile')+1] if '--profile' in args else ''
            call={'operation':args[0], 'profile':profile, 'session':args[args.index('--sso-session')+1] if '--sso-session' in args else '', 'config':Path(os.environ['AWS_CONFIG_FILE']).read_text()}
            with (Path(os.environ['HOME'])/'fixture-calls.jsonl').open('a') as output: output.write(json.dumps(call)+'\\n')
        if args[:2]==['configure','export-credentials']:
            if (Path(os.environ['HOME'])/'export-delay').exists():
                (Path(os.environ['HOME'])/'export-started').write_text('ready')
                delay=(Path(os.environ['HOME'])/'export-delay').read_text().strip()
                time.sleep(float(delay) if delay else 8)
            generation=('-'+(Path(os.environ['HOME'])/'generation').read_text()) if (Path(os.environ['HOME'])/'generation').exists() else ''
            expiry=Path(os.environ['HOME'])/('expiration'+generation)
            # Parallel role exports share one stable, fully written expiry per generation.
            with (Path(os.environ['HOME'])/'expiration.lock').open('a') as lock:
                fcntl.flock(lock.fileno(),fcntl.LOCK_EX)
                if not expiry.exists(): expiry.write_text((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(minutes=10)).isoformat())
                expiration=expiry.read_text()
            print(json.dumps({'Version':1,'AccessKeyId':'tdb-test-access-key'+generation,'SecretAccessKey':'tdb-test-secret-key'+generation,'SessionToken':'tdb-test-session-token'+generation,'Expiration':expiration}))
        elif args[:2]==['sts','get-caller-identity']:
            if mode=='sts-denied': print('AccessDeniedException',file=sys.stderr);sys.exit(1)
            if mode=='sts-auth': print("Your session has expired or credentials have changed. Please reauthenticate using 'aws login'.",file=sys.stderr);sys.exit(1)
            if os.environ.get('AWS_ACCESS_KEY_ID','').startswith('tdb-test-other'):
                account='123456789012';role='ReadOnly'
            else:
                config=configparser.RawConfigParser(); config.read(os.environ['AWS_CONFIG_FILE'])
                section=next(s for s in config.sections() if s.startswith('profile ') or s=='default')
                account=config.get(section,'sso_account_id'); role=config.get(section,'sso_role_name')
            if mode=='identity': account='210987654321'
            print(json.dumps({'Account':account,'Arn':'arn:aws:sts::'+account+':assumed-role/AWSReservedSSO_'+role+'_0123456789abcdef/synthetic'}))
        elif args[:2]==['sso','login']:
            if (Path(os.environ['HOME'])/'signin-delay').exists():
                (Path(os.environ['HOME'])/'signin-started').write_text('ready')
                time.sleep(0.8)
            if (Path(os.environ['HOME'])/'signin-fail').exists(): sys.exit(int((Path(os.environ['HOME'])/'signin-fail').read_text().strip() or '1'))
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
        func check(_ result: @autoclosure () throws -> Bool, line: UInt = #line) throws {
            guard try result() else { throw PeerFailure("An AWS service flow regression failed after \(count) checks at source line \(line).") }; count += 1
        }
        let before = try request("aws.catalog")
        guard let descriptor = (before["profiles"] as? [[String: Any]])?.first,
              let id = descriptor["id"] as? String else { throw PeerFailure("The synthetic AWS profile was not discovered.") }
        // Queue-time authorization, rather than receipt-time UI state, fences
        // an AWS mutation. Status must still respond while that queue is held.
        let authorizationEntered = DispatchSemaphore(value: 0), releaseAuthorization = DispatchSemaphore(value: 0)
        var fencedReply: [String: Any]?
        service.handle("aws.source.enable", payload: ["profileId": id], queuedAuthorization: {
            authorizationEntered.signal(); _ = releaseAuthorization.wait(timeout: .now() + 3); return false
        }) { fencedReply = $0 }
        try check(authorizationEntered.wait(timeout: .now() + 2) == .success)
        let independentStatus = service.status()
        try check(independentStatus["catalog"] is [String: Any] && fencedReply == nil)
        releaseAuthorization.signal()
        let fenceDeadline = Date().addingTimeInterval(5)
        while fencedReply == nil && Date() < fenceDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        try check(fencedReply?["code"] as? String == "control-required")
        try check((try request("aws.catalog")["sources"] as? [String])?.isEmpty == true)
        try check(try Data(contentsOf: config) == original)
        func waitCheck(_ id: String, _ expected: String) throws -> [String: Any] {
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                let catalog = try request("aws.catalog")
                if (catalog["sourceChecks"] as? [String: [String: Any]])?[id]?["state"] as? String == expected { return catalog }
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            throw PeerFailure("A synthetic AWS check did not reach its expected safe outcome.")
        }
        // Checking native access is not permission to enroll or publish it.
        try Data().write(to: root.appendingPathComponent("capture-config"))
        try check(try request("aws.check", ["profileId": id], authenticate: true)["error"] != nil)
        try check(try request("aws.check", ["profileId": id])["accepted"] as? Bool == true)
        let checkedLocal = try waitCheck(id, "ready")
        let localCheck = (checkedLocal["sourceChecks"] as! [String: [String: Any]])[id]!
        let localExpiry = localCheck["expiresAt"] as! Double
        try check(localExpiry > Date().timeIntervalSince1970)
        try check((checkedLocal["sources"] as? [String])?.isEmpty == true)
        try check((checkedLocal["accounts"] as? [[String: Any]])?.isEmpty == true)
        try check((checkedLocal["installed"] as? [[String: Any]])?.isEmpty == true)
        try check(try request("aws.credentials", ["profileId": id])["credentials"] == nil)
        try check(try Data(contentsOf: config) == original)
        let callPath = root.appendingPathComponent("fixture-calls.jsonl")
        let priorCalls = try Data(contentsOf: callPath)
        try check(try request("aws.check", ["profileId": id])["accepted"] as? Bool == true)
        try check(try Data(contentsOf: callPath) == priorCalls)
        // Classified failures never leak private provider output or turn a
        // network/permission/configuration error into a browser-login prompt.
        let failurePath = root.appendingPathComponent("check-failure")
        for (mode, expected) in [("auth", "signInRequired"), ("network", "networkUnavailable"), ("denied", "accessDenied"), ("config", "checkFailed"), ("identity", "checkFailed")] {
            try Data(mode.utf8).write(to: failurePath)
            try check(try request("aws.check", ["profileId": id, "manual": true])["accepted"] as? Bool == true)
            let failed = try waitCheck(id, expected)
            try check((failed["sources"] as? [String])?.isEmpty == true && (failed["accounts"] as? [[String: Any]])?.isEmpty == true)
            try check(!String(decoding: JSONSerialization.data(withJSONObject: failed), as: UTF8.self).contains("tdb-test-private-diagnostic"))
            try check(try Data(contentsOf: config) == original)
            let unchangedCalls = try Data(contentsOf: callPath)
            try check(try request("aws.check", ["profileId": id])["accepted"] as? Bool == true)
            try check(try Data(contentsOf: callPath) == unchangedCalls)
        }
        try FileManager.default.removeItem(at: failurePath)
        try check(try request("aws.check", ["profileId": id, "manual": true])["accepted"] as? Bool == true)
        let checkedAgain = try waitCheck(id, "ready")
        try check((checkedAgain["sourceChecks"] as? [String: [String: Any]])?[id]?["expiresAt"] as? Double == localExpiry)
        try check(!String(decoding: Data(contentsOf: callPath), as: UTF8.self).contains("\"operation\": \"sso\""))
        try FileManager.default.removeItem(at: root.appendingPathComponent("capture-config"))
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
        // Hold exactly four CLI jobs. A repeated source check coalesces;
        // different manual checks report busy instead of claiming success.
        var capacityBytes = original
        for number in 1...5 {
            capacityBytes.append(Data("\n[profile capacity-\(number)]\nsso_start_url = https://example.awsapps.com/start\nsso_region = us-east-1\nsso_account_id = 123456789012\nsso_role_name = Capacity\(number)\n".utf8))
        }
        try capacityBytes.write(to: config)
        let capacityProfiles = try request("aws.catalog")["profiles"] as! [[String: Any]]
        let capacityIDs = Dictionary(uniqueKeysWithValues: capacityProfiles.map { ($0["name"] as! String, $0["id"] as! String) })
        let capacitySource = capacityIDs["capacity-4"]!
        try check(try request("aws.source.enable", ["profileId": capacitySource])["error"] == nil)
        _ = try waitCheck(capacitySource, "ready")
        try Data("2".utf8).write(to: root.appendingPathComponent("export-delay"))
        try check(try request("aws.refresh", ["profileId": id])["accepted"] as? Bool == true)
        for number in 1...3 { try check(try request("aws.check", ["profileId": capacityIDs["capacity-\(number)"]!, "manual": true])["accepted"] as? Bool == true) }
        try check(try request("aws.refresh", ["profileId": id])["accepted"] as? Bool == true)
        try check(try request("aws.refresh", ["profileId": capacitySource])["error"] != nil)
        try check(try request("aws.check", ["profileId": capacityIDs["capacity-5"]!, "manual": true])["error"] != nil)
        try check(try request("aws.check", ["profileId": capacityIDs["capacity-5"]!, "manual": false])["accepted"] as? Bool == false)
        _ = try waitCheck(id, "ready")
        for number in 1...3 { _ = try waitCheck(capacityIDs["capacity-\(number)"]!, "ready") }
        try FileManager.default.removeItem(at: root.appendingPathComponent("export-delay"))
        try check(try request("aws.remove", ["profileId": capacitySource])["error"] == nil)
        try original.write(to: config)
        try check((try request("aws.catalog")["sources"] as? [String]) == [id])
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
        try check(try request("aws.use", ["profileId": otherProfile.id, "targetName": "fresh-receiver"])["error"] == nil)
        try check(try request("aws.source.enable", ["profileId": otherProfile.id])["error"] != nil)
        let freshReceiverConfig = try Data(contentsOf: config)
        try check(try request("aws.share", ["profileId": otherProfile.id, "targetName": "should-not-install"])["error"] != nil)
        try check(try Data(contentsOf: config) == freshReceiverConfig)
        try check(try request("aws.remove", ["profileId": otherProfile.id])["error"] == nil)
        try check(try Data(contentsOf: config) == original)
        let receiverOriginal = original + Data("\n[profile received]\nsso_start_url = https://other.awsapps.com/start\nsso_region = us-east-1\nsso_account_id = 123456789012\nsso_role_name = ReadOnly\n".utf8)
        try receiverOriginal.write(to: config)
        let cacheWriter = Process(); cacheWriter.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        cacheWriter.arguments = ["-c", "import pathlib,hashlib,json,sys; d=pathlib.Path(sys.argv[1])/'.aws/sso/cache'; d.mkdir(parents=True,exist_ok=True); p=d/(hashlib.sha1(b'https://other.awsapps.com/start').hexdigest()+'.json'); p.write_text(json.dumps({'accessToken':'tdb-test-expired-token','startUrl':'https://other.awsapps.com/start','region':'us-east-1','expiresAt':'2020-01-01T00:00:00Z'})); p.chmod(0o600)", root.path]
        cacheWriter.standardInput = FileHandle.nullDevice; cacheWriter.standardOutput = FileHandle.nullDevice; cacheWriter.standardError = FileHandle.nullDevice
        try cacheWriter.run(); cacheWriter.waitUntilExit(); try check(cacheWriter.terminationStatus == 0)
        // A prior original-profile failure must not contaminate its newly
        // installed shared provider, whose preserved SSO cache is expired.
        try Data("auth".utf8).write(to: failurePath)
        try check(try request("aws.check", ["profileId": otherProfile.id, "manual": true])["accepted"] as? Bool == true)
        _ = try waitCheck(otherProfile.id, "signInRequired")
        try check(try request("aws.use", ["profileId": otherProfile.id, "targetName": "received", "replaceSource": true])["error"] == nil)
        let receiverConfig = try Data(contentsOf: config)
        try check((try request("aws.catalog")["sourceChecks"] as? [String: [String: Any]])?[otherProfile.id] == nil)
        try Data().write(to: root.appendingPathComponent("capture-config"))
        let receiverPriorCalls = try Data(contentsOf: callPath)
        try check(try request("aws.check", ["profileId": otherProfile.id, "manual": true])["accepted"] as? Bool == true)
        let receiverChecked = try waitCheck(otherProfile.id, "ready")
        try check((receiverChecked["authentication"] as? [String: [String: Any]])?[otherProfile.id]?["state"] as? String == "expired")
        try check((receiverChecked["sources"] as? [String])?.isEmpty == true)
        let receiverCalls = try Data(contentsOf: callPath).dropFirst(receiverPriorCalls.count)
        let receiverCall = try JSONSerialization.jsonObject(with: Data(receiverCalls).dropLast()) as! [String: Any]
        try check(receiverCall["operation"] as? String == "sts" && receiverCall["config"] as? String == "")
        try check(try Data(contentsOf: config) == receiverConfig)
        for (mode, expected) in [("sts-denied", "accessDenied"), ("sts-auth", "checkFailed")] {
            try Data(mode.utf8).write(to: failurePath)
            try check(try request("aws.check", ["profileId": otherProfile.id, "manual": true])["accepted"] as? Bool == true)
            let checked = try waitCheck(otherProfile.id, expected)
            try check((checked["sources"] as? [String])?.isEmpty == true)
            try check((checked["accounts"] as? [[String: Any]])?.first?["available"] as? Bool == true)
            try check(try request("aws.sync.import", ["bundle": origin.exportBundle()])["accepted"] as? Bool == true)
            try check((try request("aws.catalog")["sourceChecks"] as? [String: [String: Any]])?[otherProfile.id]?["state"] as? String == expected)
        }
        let renewedReceiverCredentials = AWSRoleCredentials(accessKeyId: "tdb-test-other-access-renewed", secretAccessKey: "tdb-test-other-secret-renewed", sessionToken: "tdb-test-other-session-renewed", expiration: credentials.expiration + 60)
        _ = try origin.publish(profile: otherProfile, principalARN: "arn:aws:sts::123456789012:assumed-role/AWSReservedSSO_ReadOnly_0123456789abcdef/synthetic", credentials: renewedReceiverCredentials, sourceName: "Synthetic source")
        try check(try request("aws.sync.import", ["bundle": origin.exportBundle()])["accepted"] as? Bool == true)
        let renewedReceiver = try request("aws.catalog")
        try check((renewedReceiver["sourceChecks"] as? [String: [String: Any]])?[otherProfile.id] == nil)
        try check((renewedReceiver["accounts"] as? [[String: Any]])?.first?["expires"] as? Double == renewedReceiverCredentials.expiration)
        try FileManager.default.removeItem(at: failurePath)
        try FileManager.default.removeItem(at: root.appendingPathComponent("capture-config"))
        try check((try request("aws.catalog")["sources"] as? [String])?.isEmpty == true)
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
        try check((afterCancel["sources"] as? [String])?.isEmpty == true)
        try check(try Data(contentsOf: config) == receiverConfig)
        try origin.withdraw(otherProfile.id); try local.importBundle(origin.exportBundle())
        let withdrawn = try request("aws.catalog")
        try check((withdrawn["accounts"] as? [[String: Any]])?.isEmpty == true)
        try check((withdrawn["installed"] as? [[String: Any]])?.first?["descriptor"] is [String: Any])
        try check(try request("aws.check", ["profileId": otherProfile.id, "manual": true])["accepted"] as? Bool == true)
        let withdrawnCheck = try waitCheck(otherProfile.id, "checkFailed")
        try check((withdrawnCheck["sources"] as? [String])?.isEmpty == true)
        try check((withdrawnCheck["sourceChecks"] as? [String: [String: Any]])?[otherProfile.id]?["needsSharedRenewal"] as? Bool == true)
        // Reconnected peer delivery repairs missing access without a manual
        // check or local browser sign-in, even when its expiry is unchanged.
        _ = try origin.publish(profile: otherProfile, principalARN: "arn:aws:sts::123456789012:assumed-role/AWSReservedSSO_ReadOnly_0123456789abcdef/synthetic", credentials: credentials, sourceName: "Synthetic source")
        try check(try request("aws.sync.import", ["bundle": origin.exportBundle()])["accepted"] as? Bool == true)
        let reconnectedReceiver = try request("aws.catalog")
        try check((reconnectedReceiver["accounts"] as? [[String: Any]])?.first?["available"] as? Bool == true)
        try check((reconnectedReceiver["sourceChecks"] as? [String: [String: Any]])?[otherProfile.id] == nil)
        try check((reconnectedReceiver["sources"] as? [String])?.isEmpty == true)
        try check((reconnectedReceiver["signInProfile"] as? String)?.isEmpty == true)
        try check(try request("aws.remove", ["profileId": otherProfile.id])["error"] == nil)
        try check(try Data(contentsOf: config) == receiverOriginal)
        try original.write(to: config)

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
        var alternateDescriptor = aliasDescriptor
        alternateDescriptor["ssoSessionName"] = "viewer-must-not-replace-local-cache"
        try check(try aliasRequest("aws.signIn.start", ["profileId": aliasID, "descriptor": alternateDescriptor])["accepted"] as? Bool == true)
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
        try check((try aliasRequest("aws.catalog")["sources"] as? [String]) == [aliasID])
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
        func sessionRequest(_ operation: String, _ payload: [String: Any] = [:], authorize: (() -> Bool)? = nil) throws -> [String: Any] {
            var response: [String: Any]?
            sessionService.handle(operation, payload: payload, queuedAuthorization: authorize) { response = $0 }
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
        try check((cachedButExpired["sourceChecks"] as? [String: [String: Any]])?[alpha]?["state"] as? String == "ready")
        try check((cachedButExpired["sourceChecks"] as? [String: [String: Any]])?[beta]?["state"] as? String == "ready")
        // A browser-renewable/expired token cache does not itself produce an
        // authentication-required outcome when AWS credential checks succeed.
        try check((cachedButExpired["signInProfile"] as? String)?.isEmpty == true)
        let roleExpiryBeforeCheck = (cachedButExpired["accounts"] as? [[String: Any]])?.first { $0["profileId"] as? String == alpha }?["expires"] as? Double
        try check(try sessionRequest("aws.refresh", ["profileId": alpha])["accepted"] as? Bool == true)
        try check(try waitSessionReady("tdb-test-access-key", [alpha, beta, other]))
        let unchangedAccess = try sessionRequest("aws.catalog")
        try check((unchangedAccess["accounts"] as? [[String: Any]])?.first { $0["profileId"] as? String == alpha }?["expires"] as? Double == roleExpiryBeforeCheck)
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
        let sessionFailurePath = sessionRoot.appendingPathComponent("check-failure")
        try Data("auth".utf8).write(to: sessionFailurePath)
        for id in [alpha, beta] { try check(try sessionRequest("aws.refresh", ["profileId": id])["accepted"] as? Bool == true) }
        let requiredDeadline = Date().addingTimeInterval(8)
        var requiredCatalog: [String: Any] = [:]
        repeat {
            requiredCatalog = try sessionRequest("aws.catalog")
            let outcomes = requiredCatalog["sourceChecks"] as? [String: [String: Any]] ?? [:]
            if [alpha, beta].allSatisfy({ outcomes[$0]?["state"] as? String == "signInRequired" }) { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        } while Date() < requiredDeadline
        try check([alpha, beta].allSatisfy { (requiredCatalog["sourceChecks"] as? [String: [String: Any]])?[$0]?["state"] as? String == "signInRequired" })
        try check(TDBAWSStatusModel.summary(requiredCatalog, now: Date())["title"] as? String == "AWS · Sign-in needed")
        try check(try sessionRequest("aws.signIn.start", ["profileId": beta])["accepted"] as? Bool == true)
        let pendingAuth = try sessionRequest("aws.catalog")
        try check([alpha, beta].allSatisfy { (pendingAuth["sourceChecks"] as? [String: [String: Any]])?[$0]?["state"] as? String == "signInRequired" })
        try check(try sessionRequest("aws.signIn.cancel", ["profileId": alpha])["error"] != nil)
        try check(try sessionRequest("aws.catalog")["signInProfile"] as? String == beta)
        try check(try sessionRequest("aws.signIn.cancel", ["profileId": beta])["accepted"] as? Bool == true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.9))
        let cancelledSession = try sessionRequest("aws.catalog")
        try check(cancelledSession["signInProfile"] as? String == "" && authState(cancelledSession, alpha) == "expired")
        try check([alpha, beta].allSatisfy { (cancelledSession["sourceChecks"] as? [String: [String: Any]])?[$0]?["state"] as? String == "signInRequired" })
        try check(TDBAWSStatusModel.summary(cancelledSession, now: Date())["title"] as? String == "AWS · Sign-in needed")
        try check((try sessionRequest("aws.credentials", ["profileId": alpha])["credentials"] as? [String: Any])?["AccessKeyId"] as? String == "tdb-test-access-key-session-renewed")
        try Data("64".utf8).write(to: sessionRoot.appendingPathComponent("signin-fail"))
        try check(try sessionRequest("aws.signIn.start", ["profileId": alpha])["accepted"] as? Bool == true)
        let failedDeadline = Date().addingTimeInterval(5)
        var failedSession: [String: Any] = [:]
        repeat {
            failedSession = try sessionRequest("aws.catalog")
            if failedSession["signInProfile"] as? String == "" { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        } while Date() < failedDeadline
        try check(failedSession["signInProfile"] as? String == "" && authState(failedSession, beta) == "expired")
        try check([alpha, beta].allSatisfy { (failedSession["sourceChecks"] as? [String: [String: Any]])?[$0]?["state"] as? String == "signInRequired" })
        try check(TDBAWSStatusModel.summary(failedSession, now: Date())["title"] as? String == "AWS · Sign-in needed")
        try check((failedSession["accounts"] as? [[String: Any]])?.filter { $0["available"] as? Bool == true }.count == 3)
        try check((try sessionRequest("aws.credentials", ["profileId": beta])["credentials"] as? [String: Any])?["AccessKeyId"] as? String == "tdb-test-access-key-session-renewed")
        try check(Set(failedSession["sources"] as? [String] ?? []) == Set([alpha, beta, other]))
        try FileManager.default.removeItem(at: sessionRoot.appendingPathComponent("signin-fail"))
        try FileManager.default.removeItem(at: sessionFailurePath)
        // A fresh successful credential check can supersede the confirmed
        // requirement too, without treating cached-token expiry as authority.
        try check(try sessionRequest("aws.refresh", ["profileId": beta])["accepted"] as? Bool == true)
        let checkedDeadline = Date().addingTimeInterval(8)
        var checkedAfterFailure: [String: Any] = [:]
        repeat {
            checkedAfterFailure = try sessionRequest("aws.catalog")
            if (checkedAfterFailure["sourceChecks"] as? [String: [String: Any]])?[beta]?["state"] as? String == "ready" { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        } while Date() < checkedDeadline
        try check((checkedAfterFailure["sourceChecks"] as? [String: [String: Any]])?[beta]?["state"] as? String == "ready")
        try check((checkedAfterFailure["sourceChecks"] as? [String: [String: Any]])?[alpha]?["state"] as? String == "signInRequired")
        try check(authState(checkedAfterFailure, beta) == "expired")
        let healthySiblingExpiry = (checkedAfterFailure["sourceChecks"] as? [String: [String: Any]])?[beta]?["expiresAt"] as? Double
        try Data("2".utf8).write(to: sessionRoot.appendingPathComponent("export-delay"))
        try check(try sessionRequest("aws.refresh", ["profileId": beta])["accepted"] as? Bool == true)
        try check(try sessionRequest("aws.check", ["profileId": unshared, "manual": true])["accepted"] as? Bool == true)
        let earlierAttempt = try sessionRequest("aws.signIn.start", ["profileId": alpha])
        try FileManager.default.removeItem(at: sessionRoot.appendingPathComponent("export-delay"))
        let earlierAttemptID = earlierAttempt["signInAttempt"] as? String ?? ""
        try check(earlierAttempt["accepted"] as? Bool == true && UUID(uuidString: earlierAttemptID) != nil)
        let cancelledSiblingCheck = try sessionRequest("aws.catalog")
        try check((cancelledSiblingCheck["sourceChecks"] as? [String: [String: Any]])?[beta]?["state"] as? String == "ready")
        try check((cancelledSiblingCheck["sourceChecks"] as? [String: [String: Any]])?[beta]?["expiresAt"] as? Double == healthySiblingExpiry)
        try check((cancelledSiblingCheck["sourceChecks"] as? [String: [String: Any]])?[unshared] == nil)
        try check(try sessionRequest("aws.signIn.cancel", ["profileId": alpha, "signInAttempt": earlierAttemptID])["accepted"] as? Bool == true)
        try check((try sessionRequest("aws.catalog")["sourceChecks"] as? [String: [String: Any]])?[beta]?["state"] as? String == "ready")
        let newerAttempt = try sessionRequest("aws.signIn.start", ["profileId": alpha])
        let newerAttemptID = newerAttempt["signInAttempt"] as? String ?? ""
        try check(newerAttempt["accepted"] as? Bool == true && newerAttemptID != earlierAttemptID)
        try check(try sessionRequest("aws.signIn.cancel", ["profileId": alpha, "signInAttempt": earlierAttemptID])["error"] != nil)
        try check(try sessionRequest("aws.catalog")["signInAttempt"] as? String == newerAttemptID)
        try check(try sessionRequest("aws.signIn.cancel", ["profileId": alpha, "signInAttempt": newerAttemptID])["accepted"] as? Bool == true)
        try Data("64".utf8).write(to: sessionRoot.appendingPathComponent("signin-fail"))
        try check(try sessionRequest("aws.signIn.start", ["profileId": alpha])["accepted"] as? Bool == true)
        let siblingFailureDeadline = Date().addingTimeInterval(5)
        var siblingAfterFailure: [String: Any] = [:]
        repeat {
            siblingAfterFailure = try sessionRequest("aws.catalog")
            if siblingAfterFailure["signInProfile"] as? String == "" { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        } while Date() < siblingFailureDeadline
        try check(siblingAfterFailure["signInProfile"] as? String == "")
        try check((siblingAfterFailure["sourceChecks"] as? [String: [String: Any]])?[beta]?["state"] as? String == "ready")
        try check((siblingAfterFailure["sourceChecks"] as? [String: [String: Any]])?[beta]?["expiresAt"] as? Double == healthySiblingExpiry)
        try check(AWSProfilePresentation.rows(catalog: siblingAfterFailure).first { $0.id == beta }?.rowState(isSource: true, sourceStatus: nil, isSigningIn: false).primaryAction == .ready)
        try FileManager.default.removeItem(at: sessionRoot.appendingPathComponent("signin-fail"))
        try check(try sessionRequest("aws.signIn.start", ["profileId": beta])["accepted"] as? Bool == true)
        try check(try waitSessionReady("tdb-test-access-key-session-renewed", [alpha, beta]))
        let successfullyRetried = try sessionRequest("aws.catalog")
        try check([alpha, beta].allSatisfy { (successfullyRetried["sourceChecks"] as? [String: [String: Any]])?[$0]?["state"] as? String == "ready" })
        try check(TDBAWSStatusModel.summary(successfullyRetried, now: Date())["state"] as? String == "ready")
        try check(authState(try sessionRequest("aws.catalog"), alpha) == "current")
        try check(try Data(contentsOf: sessionConfig) == sessionBytes)

        // New shared credentials do not change the native source's CLI
        // provider. Switching requires explicit confirmation and a usable
        // non-local copy; it stops only the obsolete local publisher.
        let recoveryProfile = try JSONDecoder().decode(AWSProfileDescriptor.self, from: JSONSerialization.data(withJSONObject: discovered.first { $0["id"] as? String == alpha }!))
        let incomingOrigin = SharedAWSStore(root: sessionRoot.appendingPathComponent("incoming-source"))
        let ownRecoveryExpiry = (try sessionRequest("aws.catalog")["accounts"] as! [[String: Any]]).first { $0["profileId"] as? String == alpha }!["expires"] as! Double
        let incomingCredentials = AWSRoleCredentials(accessKeyId: "tdb-test-other-recovery", secretAccessKey: "tdb-test-other-recovery-secret", sessionToken: "tdb-test-other-recovery-session", expiration: ownRecoveryExpiry - 60)
        let recoveryARN = "arn:aws:sts::123456789012:assumed-role/AWSReservedSSO_ReadOnly_0123456789abcdef/synthetic"
        _ = try incomingOrigin.publish(profile: recoveryProfile, principalARN: recoveryARN, credentials: incomingCredentials, sourceName: "Incoming fixture Mac")
        try check(try sessionRequest("aws.sync.import", ["bundle": incomingOrigin.exportBundle()])["accepted"] as? Bool == true)
        let recoveryCatalog = try sessionRequest("aws.catalog")
        try check((recoveryCatalog["accounts"] as? [[String: Any]])?.first { $0["profileId"] as? String == alpha }?["incomingAvailable"] as? Bool == true)
        try check((recoveryCatalog["accounts"] as? [[String: Any]])?.first { $0["profileId"] as? String == alpha }?["expires"] as? Double == ownRecoveryExpiry)
        try check((recoveryCatalog["accounts"] as? [[String: Any]])?.first { $0["profileId"] as? String == alpha }?["incomingExpires"] as? Double == incomingCredentials.expiration)
        try check(try Data(contentsOf: sessionConfig) == sessionBytes)
        try check(try sessionRequest("aws.use", ["profileId": alpha, "targetName": "alpha", "stopSource": true])["error"] != nil)
        try incomingOrigin.withdraw(alpha)
        try check(try sessionRequest("aws.sync.import", ["bundle": incomingOrigin.exportBundle()])["accepted"] as? Bool == true)
        let switchPayload: [String: Any] = ["profileId": alpha, "targetName": "alpha", "stopSource": true, "replaceSource": true]
        try check(try sessionRequest("aws.use", switchPayload)["error"] != nil)
        try check(try Data(contentsOf: sessionConfig) == sessionBytes)
        _ = try incomingOrigin.publish(profile: recoveryProfile, principalARN: recoveryARN, credentials: incomingCredentials, sourceName: "Incoming fixture Mac")
        try check(try sessionRequest("aws.sync.import", ["bundle": incomingOrigin.exportBundle()])["accepted"] as? Bool == true)
        let lostController = try sessionRequest("aws.use", switchPayload, authorize: {
            guard let current = try? String(contentsOf: sessionConfig, encoding: .utf8) else { return false }
            return !current.contains("credential_process")
        })
        try check(lostController["code"] as? String == "control-required")
        try check(try Data(contentsOf: sessionConfig) == sessionBytes)
        let recoveryServiceFile = sessionRoot.appendingPathComponent("aws-service.json")
        let savedService = try Data(contentsOf: recoveryServiceFile)
        try FileManager.default.removeItem(at: recoveryServiceFile)
        try FileManager.default.createDirectory(at: recoveryServiceFile, withIntermediateDirectories: false)
        try check(try sessionRequest("aws.use", switchPayload)["error"] != nil)
        try check(try Data(contentsOf: sessionConfig) == sessionBytes)
        try check(Set(try sessionRequest("aws.catalog")["sources"] as? [String] ?? []) == Set([alpha, beta, other]))
        try FileManager.default.removeItem(at: recoveryServiceFile)
        try savedService.write(to: recoveryServiceFile); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recoveryServiceFile.path)
        try check(try sessionRequest("aws.use", switchPayload)["error"] == nil)
        let switched = try sessionRequest("aws.catalog")
        try check(Set(switched["sources"] as? [String] ?? []) == Set([beta, other]))
        try check((switched["accounts"] as? [[String: Any]])?.first { $0["profileId"] as? String == alpha }?["available"] as? Bool == true)
        try check((switched["accounts"] as? [[String: Any]])?.first { $0["profileId"] as? String == alpha }?["local"] as? Bool == false)
        try check((switched["accounts"] as? [[String: Any]])?.first { $0["profileId"] as? String == alpha }?["expires"] as? Double == incomingCredentials.expiration)
        try check((switched["installed"] as? [[String: Any]])?.first { $0["profileId"] as? String == alpha }?["source"] as? Bool == false)
        try Data("auth".utf8).write(to: sessionFailurePath)
        try check(try sessionRequest("aws.check", ["profileId": alpha, "manual": true])["accepted"] as? Bool == true)
        let receiverReadyDeadline = Date().addingTimeInterval(8)
        var switchedCheck: [String: Any] = [:]
        repeat {
            switchedCheck = try sessionRequest("aws.catalog")
            if (switchedCheck["sourceChecks"] as? [String: [String: Any]])?[alpha]?["state"] as? String == "ready" { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        } while Date() < receiverReadyDeadline
        try check((switchedCheck["sourceChecks"] as? [String: [String: Any]])?[alpha]?["state"] as? String == "ready")
        try check(Set(switchedCheck["sources"] as? [String] ?? []) == Set([beta, other]))
        try FileManager.default.removeItem(at: sessionFailurePath)
        try check(try sessionRequest("aws.remove", ["profileId": alpha])["error"] == nil)
        try check(try Data(contentsOf: sessionConfig) == sessionBytes)
        try check(Set(try sessionRequest("aws.catalog")["sources"] as? [String] ?? []) == Set([beta, other]))

        // A remote catalog can offer SSO metadata for an explicit sign-in on
        // the viewing Mac. No user config or source enrollment precedes auth.
        let viewerRoot = root.appendingPathComponent("viewing-sign-in")
        try FileManager.default.createDirectory(at: viewerRoot.appendingPathComponent("aws-fixture"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let viewerCLI = viewerRoot.appendingPathComponent("aws")
        try FileManager.default.copyItem(at: fake, to: viewerCLI)
        setenv("TERMINALDB_AWS_QA_EXECUTABLE", viewerCLI.path, 1)
        let viewerConfig = viewerRoot.appendingPathComponent("aws-fixture/config")
        try Data().write(to: viewerConfig); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: viewerConfig.path)
        let viewer = SharedAWSService(root: viewerRoot)
        func viewerRequest(_ operation: String, _ payload: [String: Any] = [:]) throws -> [String: Any] {
            var response: [String: Any]?
            viewer.handle(operation, payload: payload) { response = $0 }
            let deadline = Date().addingTimeInterval(10)
            while response == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            guard let response else { throw PeerFailure("The synthetic viewing-Mac AWS operation did not finish.") }
            return response
        }
        let offered = AWSProfileDescriptor(name: "offered-sso", kind: "sso", region: "us-east-1", ssoStartURL: "https://example.awsapps.com/start", ssoRegion: "us-east-1", accountID: "123456789012", roleName: "ReadOnly", ssoSessionName: "offered-session")
        let offeredFields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(offered)) as! [String: Any]
        let offeredLogin = AWSProfileDescriptor(name: "offered-login", kind: "login", loginSession: "arn:aws:iam::123456789012:user/synthetic")
        let loginFields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(offeredLogin)) as! [String: Any]
        try check(try viewerRequest("aws.signIn.start", ["profileId": offeredLogin.id, "descriptor": loginFields])["error"] != nil)
        try check(try viewerRequest("aws.signIn.start", ["profileId": String(repeating: "f", count: 64), "descriptor": offeredFields])["error"] != nil)
        try check((try viewerRequest("aws.catalog")["sources"] as? [String])?.isEmpty == true)
        try check(try Data(contentsOf: viewerConfig).isEmpty)
        try Data().write(to: viewerRoot.appendingPathComponent("signin-delay"))
        try check(try viewerRequest("aws.signIn.start", ["profileId": offered.id, "descriptor": offeredFields])["accepted"] as? Bool == true)
        try check((try viewerRequest("aws.catalog")["sources"] as? [String])?.isEmpty == true)
        let viewerDeadline = Date().addingTimeInterval(8)
        var viewerReady = false
        while !viewerReady && Date() < viewerDeadline {
            let catalog = try viewerRequest("aws.catalog")
            viewerReady = (catalog["sourceChecks"] as? [String: [String: Any]])?[offered.id]?["state"] as? String == "ready"
            if !viewerReady { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        }
        try check(viewerReady)
        let viewerResult = try viewerRequest("aws.catalog")
        try check(viewerResult["sources"] as? [String] == [offered.id])
        try check((viewerResult["installed"] as? [[String: Any]])?.isEmpty == true)
        try check(try Data(contentsOf: viewerConfig).isEmpty)
        return count
    }
}
