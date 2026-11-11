import Foundation
import Darwin
import CryptoKit

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
// What this Mac knows about one IAM Identity Center sign-in session. AWS
// never exposes a session's end time to clients, so the duration is either
// the AWS default, a value the user entered, or an upper bound learned from
// an observed end. `fresh` means a new session is known to have started at
// `signedInAt` (rather than an existing one being reused).
struct SharedAWSSessionRecord: Codable, Equatable {
    static let defaultDuration: Double = 28_800
    static let minimumDuration: Double = 900
    static let maximumDuration: Double = 7_776_000
    static let sources: Set<String> = ["default", "learned", "custom"]

    var signedInAt: Double?
    var fresh = false
    var endedAt: Double?
    var duration = SharedAWSSessionRecord.defaultDuration
    var durationSource = "default"

    init() {}
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        signedInAt = try fields.decodeIfPresent(Double.self, forKey: .signedInAt)
        fresh = try fields.decodeIfPresent(Bool.self, forKey: .fresh) ?? false
        endedAt = try fields.decodeIfPresent(Double.self, forKey: .endedAt)
        duration = try fields.decodeIfPresent(Double.self, forKey: .duration) ?? Self.defaultDuration
        durationSource = try fields.decodeIfPresent(String.self, forKey: .durationSource) ?? "default"
    }

    var valid: Bool {
        (signedInAt.map { $0.isFinite && $0 >= 0 } ?? true) && (endedAt.map { $0.isFinite && $0 >= 0 } ?? true) &&
            duration.isFinite && duration >= Self.minimumDuration && duration <= Self.maximumDuration &&
            Self.sources.contains(durationSource)
    }
    // A confirmed end after the last known start means the session is over.
    var ended: Bool { endedAt.map { $0 > (signedInAt ?? 0) } ?? false }
}

// Everything a browser sign-in needs after asynchronous restart steps.
private struct SharedAWSSignInContext {
    let profile: AWSProfileDescriptor
    let key: String
    let attempt: String
    let sessionKey: String?
    let renewalGeneration: UInt64
    let executable: URL
    let environment: [String: String]
    let endedBefore: Bool
    let missingBefore: Bool
}

private struct SharedAWSLocalDocument: Codable {
    var sources: [String: SharedAWSLocalSource] = [:]
    // Optional so documents written before session tracking still decode.
    var sessions: [String: SharedAWSSessionRecord]? = nil
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
    // Fences OIDC reachability probes so a cancelled check cannot report.
    private var pendingProbes: [String: UUID] = [:]
    // SSO token cache files of known sessions. Owned by statusWatchQueue so
    // an external `aws sso login` is noticed without polling AWS.
    private var watchedCacheFiles: [URL] = []
    private static let maximumLocalSources = 16
    private static let maximumSessionRecords = 256
    static let restartPhase = "Ending the current AWS session so the new sign-in starts a full session…"
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
                    guard payload["restart"] == nil || Self.isBoolean(payload["restart"]) else {
                        throw PeerFailure("Choose whether this sign-in restarts the AWS session.")
                    }
                    let restart = payload["restart"] as? Bool == true
                    // One browser sign-in owns the SSO session, not just its
                    // selected account/role. Fence every related renewal before
                    // authentication so old exports cannot overwrite new access.
                    let sessionKey = try self.sessionKey(for: profile)
                    if restart {
                        guard profile.kind == "sso", sessionKey != nil, try self.configuration.resolvedSSOSessionName(for: profile) != nil else {
                            throw PeerFailure("Only an AWS SSO profile that uses a named sso-session can restart its session.")
                        }
                    }
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
                    let attempt = UUID().uuidString
                    // Evidence about the session before this sign-in decides
                    // whether its completion starts a new, full-length session.
                    let before = sessionKey.map { self.sessionEvidence($0, profile: profile) } ?? (ended: false, missing: false)
                    let context = SharedAWSSignInContext(profile: profile, key: "signin:" + profile.id, attempt: attempt, sessionKey: sessionKey,
                                                         renewalGeneration: renewalGeneration, executable: executable, environment: environment,
                                                         endedBefore: before.ended, missingBefore: before.missing)
                    self.signInProfile = profile.id; self.signInAttempt = attempt; self.signInSessionKey = sessionKey
                    if restart && !before.missing {
                        self.phase = Self.restartPhase
                        self.notify()
                        self.beginRestart(context)
                    } else {
                        try self.launchLogin(context, fresh: before.ended || before.missing)
                    }
                    reply(["accepted": true, "signInAttempt": attempt])
                case "aws.session.configure":
                    // The SSO session identifier is the catalog's ssoSessions id.
                    // "ssoSessionId" is accepted too because peer requests also
                    // use "sessionId" for the terminal session.
                    guard let id = (payload["ssoSessionId"] ?? payload["sessionId"]) as? String, Self.validID(id) else {
                        throw PeerFailure("Choose an AWS SSO session.")
                    }
                    guard self.sessionGroups(try self.localProfiles())[id] != nil else {
                        throw PeerFailure("This AWS SSO session is no longer configured on this Mac.")
                    }
                    var record = self.document.sessions?[id] ?? SharedAWSSessionRecord()
                    let value = payload["duration"]
                    if value == nil || value is NSNull {
                        record.duration = SharedAWSSessionRecord.defaultDuration; record.durationSource = "default"
                    } else {
                        guard !Self.isBoolean(value), let number = value as? NSNumber, number.doubleValue.isFinite else {
                            throw PeerFailure("Enter the AWS session length in seconds.")
                        }
                        let seconds = number.doubleValue
                        if seconds == 0 {
                            record.duration = SharedAWSSessionRecord.defaultDuration; record.durationSource = "default"
                        } else {
                            guard seconds >= SharedAWSSessionRecord.minimumDuration, seconds <= SharedAWSSessionRecord.maximumDuration else {
                                throw PeerFailure("Choose an AWS session length from 15 minutes to 90 days.")
                            }
                            record.duration = seconds; record.durationSource = "custom"
                        }
                    }
                    let previous = self.document.sessions
                    self.setSession(id, record)
                    do { try self.save() } catch { self.document.sessions = previous; throw error }
                    self.notify(); reply(try self.snapshotCatalog())
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
            // Session timing is advisory. Drop damaged records rather than
            // blocking AWS access over them.
            let sessions = (document.sessions ?? [:]).filter { Self.validID($0.key) && $0.value.valid }
            document.sessions = sessions.isEmpty ? nil : (sessions.count <= Self.maximumSessionRecords ? sessions : nil)
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
        pendingProbes.removeValue(forKey: id)
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
    // Launches the browser sign-in itself. `fresh` records that completing it
    // starts a new Identity Center session rather than reusing an active one.
    private func launchLogin(_ context: SharedAWSSignInContext, fresh: Bool) throws {
        let profile = context.profile, key = context.key, sessionKey = context.sessionKey
        let renewalGeneration = context.renewalGeneration
        let command = SharedAWSCommand(queue: queue)
        jobs[key] = command
        phase = profile.kind == "sso" ? "Complete AWS sign-in in your browser. This signs in all profiles using this SSO session on this Mac." : "Complete AWS sign-in in your browser on this Mac."
        notify()
        do {
            try command.start(executable: context.executable, arguments: try configuration.loginArguments(for: profile),
                              environment: context.environment, timeout: 600, capture: false) { [weak self, weak command] result in
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
                            if let sessionKey, fresh {
                                var record = self.document.sessions?[sessionKey] ?? SharedAWSSessionRecord()
                                record.signedInAt = Date().timeIntervalSince1970; record.fresh = true; record.endedAt = nil
                                self.setSession(sessionKey, record)
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
        } catch {
            if jobs[key] === command { jobs.removeValue(forKey: key) }
            if signInAttempt == context.attempt { signInProfile = nil; signInAttempt = nil; signInSessionKey = nil }
            command.cancel()
            throw error
        }
    }

    // Restart ends the current Identity Center session before signing in,
    // because `aws sso login` reuses an active session and keeps its end
    // time. AWS CLI's own `sso logout` is global, so it runs only in a
    // private HOME holding a copy of this one session's token cache.
    // Issued role credentials are never removed and keep working until
    // they expire.
    private func beginRestart(_ context: SharedAWSSignInContext) {
        let sandbox = root.appendingPathComponent("aws-restart-" + UUID().uuidString)
        let workQueue = queue
        let cleanup: () -> Void = {
            try? FileManager.default.removeItem(at: sandbox)
            // A terminated CLI may still be exiting. Sweep again after the
            // command's forced-kill window so nothing is left behind.
            workQueue.asyncAfter(deadline: .now() + 3) { try? FileManager.default.removeItem(at: sandbox) }
        }
        let profile = context.profile, key = context.key
        func current(_ command: SharedAWSCommand?) -> Bool {
            command != nil && jobs[key] === command && signInAttempt == context.attempt
        }
        func proceed(restarted: Bool, endedDuringRestart: Bool = false) {
            guard signInAttempt == context.attempt else { return }
            do { try launchLogin(context, fresh: restarted || endedDuringRestart || context.endedBefore || context.missingBefore) }
            catch {
                phase = "AWS sign-in did not finish. Try Sign In again. Existing cached profile access is kept until it expires."
                notify()
            }
        }
        var environment = context.environment
        let cache = sandbox.appendingPathComponent(".aws/sso/cache")
        do {
            try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for path in [".aws", ".aws/sso", ".aws/sso/cache"] {
                try FileManager.default.createDirectory(at: sandbox.appendingPathComponent(path), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            guard try configuration.copySSOSessionCache(for: profile, into: cache) else {
                cleanup(); proceed(restarted: false); return
            }
            environment["HOME"] = sandbox.path
            // Export without a role-credential cache forces GetRoleCredentials,
            // so the CLI refreshes an expired access token into the sandbox
            // copy. The credentials are discarded unread.
            let refresh = SharedAWSCommand(queue: queue)
            jobs[key] = refresh
            try refresh.start(executable: context.executable,
                              arguments: ["configure", "export-credentials", "--profile", profile.name, "--format", "process", "--no-cli-pager", "--cli-connect-timeout", "5", "--cli-read-timeout", "10"],
                              environment: environment, timeout: 30, capture: false) { [weak self, weak refresh] result in
                guard let self, current(refresh) else { cleanup(); return }
                if case .failure(let error) = result {
                    cleanup()
                    let failure = error as? SharedAWSCommandFailure
                    proceed(restarted: false, endedDuringRestart: failure?.state == .signInRequired && failure?.requiresReachabilityProbe == false)
                    return
                }
                let logout = SharedAWSCommand(queue: self.queue)
                self.jobs[key] = logout
                do {
                    try logout.start(executable: context.executable, arguments: ["sso", "logout", "--no-cli-pager", "--cli-connect-timeout", "5", "--cli-read-timeout", "10"],
                                     environment: environment, timeout: 30, capture: false) { [weak self, weak logout] result in
                        guard let self, current(logout) else { cleanup(); return }
                        cleanup()
                        guard case .success = result else { proceed(restarted: false); return }
                        // The server-side session is over. Remove only this
                        // session's stale local token so status cannot report
                        // it as signed in while the new sign-in is pending.
                        try? self.configuration.removeSSOSessionCache(for: profile)
                        proceed(restarted: true)
                    }
                } catch { cleanup(); proceed(restarted: false) }
            }
        } catch { cleanup(); proceed(restarted: false) }
    }

    private static func isBoolean(_ value: Any?) -> Bool {
        guard let value else { return false }
        return CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
    }

    // Local SSO profiles grouped by the sign-in session they share.
    private func sessionGroups(_ profiles: [AWSProfileDescriptor]) -> [String: [AWSProfileDescriptor]] {
        var groups: [String: [AWSProfileDescriptor]] = [:]
        for profile in profiles where profile.kind == "sso" {
            guard let key = try? sessionKey(for: profile) else { continue }
            groups[key, default: []].append(profile)
        }
        return groups
    }
    private func setSession(_ key: String, _ record: SharedAWSSessionRecord) {
        var sessions = document.sessions ?? [:]
        if sessions[key] == nil, sessions.count >= Self.maximumSessionRecords,
           let oldest = sessions.min(by: { max($0.value.signedInAt ?? 0, $0.value.endedAt ?? 0) < max($1.value.signedInAt ?? 0, $1.value.endedAt ?? 0) })?.key {
            sessions.removeValue(forKey: oldest)
        }
        sessions[key] = record
        document.sessions = sessions
    }
    // A session is confirmed over when its record says so, or when any of its
    // profiles failed a check with sign-in required since it last started.
    private func confirmedEnded(_ key: String, profileIDs: Set<String>) -> Bool {
        let record = document.sessions?[key]
        if record?.ended == true { return true }
        let since = record?.signedInAt ?? 0
        return profileIDs.contains { id in
            sourceChecks[id].map { $0.state == .signInRequired && $0.checkedAt >= since } ?? false
        }
    }
    private func sessionEvidence(_ key: String, profile: AWSProfileDescriptor) -> (ended: Bool, missing: Bool) {
        let members = (try? localProfiles()).map { sessionGroups($0)[key] ?? [] } ?? []
        let ids = Set(members.map(\.id) + [profile.id])
        return (confirmedEnded(key, profileIDs: ids), !configuration.ssoSessionCacheStatus(for: profile).present)
    }
    // An observed end is an upper bound on the session length, so learning
    // only ever shortens the expected duration, in whole 15 minute steps.
    private func recordSessionEnd(_ profile: AWSProfileDescriptor) {
        guard let key = try? sessionKey(for: profile) else { return }
        var record = document.sessions?[key] ?? SharedAWSSessionRecord()
        guard !record.ended else { return }
        let now = Date().timeIntervalSince1970
        record.endedAt = now
        // A missing token cache means someone signed out deliberately (for
        // example `aws sso logout`). That says nothing about session length.
        let rejectedByAWS = configuration.ssoSessionCacheStatus(for: profile).present
        if rejectedByAWS, record.fresh, let start = record.signedInAt, record.durationSource != "custom", now - start < record.duration - 60 {
            let minimum = SharedAWSSessionRecord.minimumDuration
            record.duration = max(minimum, floor((now - start) / minimum) * minimum)
            record.durationSource = "learned"
        }
        setSession(key, record)
        try? save()
    }
    // Notices a sign-in made outside TerminalDB, such as `aws sso login` in a
    // terminal: a current token written after the confirmed end belongs to a
    // new session that started when the cache file was written.
    private func reconcileSessions(_ groups: [String: [AWSProfileDescriptor]]) {
        var renew: Set<String> = []
        var changed = false
        for (key, profiles) in groups where key != signInSessionKey {
            guard var record = document.sessions?[key], record.ended, let endedAt = record.endedAt, let first = profiles.first else { continue }
            let cache = configuration.ssoSessionCacheStatus(for: first)
            guard cache.readable, cache.accessTokenCurrent, let modified = cache.modifiedAt, modified > endedAt else { continue }
            record.signedInAt = modified; record.fresh = true; record.endedAt = nil
            setSession(key, record); changed = true
            for id in Set(profiles.map(\.id)) where sourceChecks[id]?.state == .signInRequired { sourceChecks.removeValue(forKey: id) }
            for source in document.sources.values where (try? sessionKey(for: source.descriptor)) == key { renew.insert(source.descriptor.id) }
        }
        if changed { try? save() }
        guard !renew.isEmpty else { return }
        let generation = signInRenewalGeneration
        queue.async { [weak self] in self?.refreshSignedInSources(renew.sorted(), generation: generation) }
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
        let groups = sessionGroups(local)
        reconcileSessions(groups)
        var authentication: [String: [String: Any]] = [:]
        for profile in local where authentication[profile.id] == nil {
            var status = configuration.authenticationStatus(for: profile)
            if let key = try? sessionKey(for: profile) { status["sessionId"] = key }
            authentication[profile.id] = status
        }
        let ssoSessions = ssoSessionCatalog(groups)
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
                "ssoSessions": ssoSessions,
                "sourceChecks": sourceChecks.mapValues(\.metadata),
                "sources": document.sources.keys.sorted()]
    }
    // One entry per SSO sign-in session. Metadata only: token values never
    // leave AWSProfileConfiguration. Unknown times are omitted, not null.
    private func ssoSessionCatalog(_ groups: [String: [AWSProfileDescriptor]]) -> [[String: Any]] {
        var files: [URL] = []
        var entries: [[String: Any]] = []
        for (key, profiles) in groups {
            guard let first = profiles.first else { continue }
            let name = (try? configuration.resolvedSSOSessionName(for: first)) ?? ""
            let cache = configuration.ssoSessionCacheStatus(for: first)
            if let file = configuration.ssoSessionCacheFile(for: first) { files.append(file) }
            let record = document.sessions?[key] ?? SharedAWSSessionRecord()
            let ids = Array(Set(profiles.map(\.id))).sorted()
            let state: String
            if signInSessionKey == key { state = "signingIn" }
            else if !cache.present || confirmedEnded(key, profileIDs: Set(ids)) { state = "signedOut" }
            else if cache.readable && (cache.hasRefreshToken || cache.accessTokenCurrent) { state = "signedIn" }
            else { state = "unknown" }
            var entry: [String: Any] = ["id": key, "name": name, "startURL": first.ssoStartURL, "profileIds": ids, "state": state,
                                        "duration": record.duration, "durationSource": record.durationSource,
                                        "canRestart": !name.isEmpty && state == "signedIn"]
            if let start = record.signedInAt { entry["signedInAt"] = start; entry["expectedEnd"] = start + record.duration }
            if let ended = record.endedAt { entry["endedAt"] = ended }
            entries.append(entry)
        }
        statusWatchQueue.async { [weak self] in self?.watchedCacheFiles = files.sorted { $0.path < $1.path } }
        return entries.sorted {
            let left = $0["name"] as? String ?? "", right = $1["name"] as? String ?? ""
            return left == right ? ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") : left < right
        }
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
        for path in [config, root.appendingPathComponent("aws-service.json"), root.appendingPathComponent("shared-aws.json")] + watchedCacheFiles {
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
                } catch {
                    guard let failure = error as? SharedAWSCommandFailure, failure.requiresReachabilityProbe else {
                        self.finishRefresh(id, expiry: nil, failure: (error as? SharedAWSCommandFailure)?.state ?? .checkFailed, profile: profile); completion?(); return
                    }
                    self.resolveAmbiguousRefresh(profile, failure) { state in
                        if let state { self.finishRefresh(id, expiry: nil, failure: state, profile: profile) }
                        completion?()
                    }
                }
            }
        } catch { jobs.removeValue(forKey: "refresh:" + id); finishRefresh(id, expiry: nil, failure: (error as? SharedAWSCommandFailure)?.state ?? .checkFailed, profile: profile); completion?() }
    }
    // Resolves a bare "token has expired and refresh failed" by probing the
    // session's OIDC endpoint. A nil state means the check was cancelled or
    // superseded while the probe ran and must not report.
    private func resolveAmbiguousRefresh(_ profile: AWSProfileDescriptor, _ failure: SharedAWSCommandFailure,
                                         completion: @escaping (SharedAWSCheckState?) -> Void) {
        let token = UUID()
        pendingProbes[profile.id] = token
        SharedAWSReachability.probe(region: profile.ssoRegion, root: root, queue: queue) { [weak self] reachable in
            guard let self, self.pendingProbes[profile.id] == token else { completion(nil); return }
            self.pendingProbes.removeValue(forKey: profile.id)
            completion(failure.resolved(reachable: reachable))
        }
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
                    // STS runs with issued role credentials, never an SSO
                    // token, so an ambiguous refresh message is not sign-in.
                    let failure = error as? SharedAWSCommandFailure
                    let outcome = failure.map { $0.requiresReachabilityProbe ? .checkFailed : $0.state } ?? .checkFailed
                    self.finishRefresh(profile.id, expiry: nil, failure: receiving && outcome == .signInRequired ? .checkFailed : outcome,
                                       profile: receiving ? nil : profile)
                }
                completion?()
            }
        } catch { jobs.removeValue(forKey: "refresh:" + profile.id); finishRefresh(profile.id, expiry: nil, failure: (error as? SharedAWSCommandFailure)?.state ?? .checkFailed); completion?() }
    }
    private func finishRefresh(_ id: String, expiry: Double?, failure: SharedAWSCheckState = .checkFailed,
                               needsSharedRenewal: Bool = false, profile: AWSProfileDescriptor? = nil) {
        renewing.remove(id)
        let state: SharedAWSCheckState = expiry == nil ? failure : .ready
        sourceChecks[id] = SharedAWSAccessCheck(state: state, checkedAt: Date().timeIntervalSince1970,
                                                expiresAt: expiry ?? sourceChecks[id]?.expiresAt,
                                                needsSharedRenewal: needsSharedRenewal)
        // A confirmed sign-in requirement on a local SSO profile is the only
        // evidence this Mac gets that its Identity Center session ended.
        if state == .signInRequired, let profile, profile.kind == "sso" { recordSessionEnd(profile) }
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
        # A HOME other than the fixture root is a restart sandbox. Record what
        # it holds, mimic botocore's in-place token refresh and AWS CLI's
        # global sso logout, and never touch the fixture's real HOME.
        control=Path(sys.argv[0]).resolve().parent
        home=Path(os.environ['HOME']).resolve()
        if home!=control:
            cache=home/'.aws/sso/cache'
            def record(entry):
                with (control/'restart-calls.jsonl').open('a') as output: output.write(json.dumps(entry)+'\\n')
            record({'operation':' '.join(args[:2]),'home':str(home),'files':sorted(p.name for p in cache.iterdir()) if cache.exists() else []})
            if args[:2]==['configure','export-credentials']:
                if (control/'restart-delay').exists():
                    (control/'restart-started').write_text('ready'); time.sleep(5)
                if (control/'restart-refresh-fail').exists():
                    print('aws: [ERROR]: Error when retrieving token from sso: Token has expired and refresh failed',file=sys.stderr);sys.exit(255)
                for token in cache.iterdir():
                    value=json.loads(token.read_text()); value['accessToken']='tdb-test-refreshed-token'
                    value['expiresAt']=(datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=1)).strftime('%Y-%m-%dT%H:%M:%SZ')
                    token.write_text(json.dumps(value))
                print(json.dumps({'Version':1,'AccessKeyId':'tdb-test-sandbox-key','SecretAccessKey':'tdb-test-sandbox-secret','SessionToken':'tdb-test-sandbox-session','Expiration':(datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(minutes=10)).isoformat()}))
                sys.exit(0)
            if args[:2]==['sso','logout']:
                if (control/'restart-logout-fail').exists(): sys.exit(255)
                record({'operation':'logout-api','refreshed':[json.loads(p.read_text()).get('accessToken')=='tdb-test-refreshed-token' for p in cache.iterdir()] if cache.exists() else []})
                for p in (list(cache.iterdir()) if cache.exists() else []): p.unlink()
                roles=home/'.aws/cli/cache'
                for p in (list(roles.iterdir()) if roles.exists() else []): p.unlink()
                sys.exit(0)
            sys.exit(1)
        mode=(Path(os.environ['HOME'])/'check-failure').read_text().strip() if (Path(os.environ['HOME'])/'check-failure').exists() else ''
        if args[:2]==['configure','export-credentials']:
            messages={
                'refresh': 'aws: [ERROR]: Error when retrieving token from sso: Token has expired and refresh failed',
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
                token.write_text(json.dumps({'accessToken':'tdb-test-sso-token','refreshToken':'tdb-test-refresh-token','startUrl':config.get(section,'sso_start_url'),'region':config.get(section,'sso_region'),'expiresAt':(datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=1)).strftime('%Y-%m-%dT%H:%M:%SZ')}))
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
        for (mode, expected) in [("auth", "signInRequired"), ("refresh", "signInRequired"), ("network", "networkUnavailable"), ("denied", "accessDenied"), ("config", "checkFailed"), ("identity", "checkFailed")] {
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
        count += try sessionLifecycle(root: root.appendingPathComponent("session-lifecycle"), fake: fake)
        return count
    }

    // Session timing, ambiguous refresh failures, external sign-in detection
    // and the sandboxed restart, using only disposable fixture files.
    private static func sessionLifecycle(root: URL, fake: URL) throws -> Int {
        var count = 0
        func check(_ result: @autoclosure () throws -> Bool, line: UInt = #line) throws {
            guard try result() else { throw PeerFailure("An AWS session lifecycle regression failed after \(count) checks at source line \(line).") }; count += 1
        }
        let files = FileManager.default
        try files.createDirectory(at: root.appendingPathComponent("aws-fixture"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let cli = root.appendingPathComponent("aws")
        try files.copyItem(at: fake, to: cli)
        setenv("TERMINALDB_AWS_QA_EXECUTABLE", cli.path, 1)
        try Data().write(to: root.appendingPathComponent("capture-config"))
        func section(_ name: String, role: String, session: String) -> String {
            "[profile \(name)]\nsso_session = \(session)\nsso_account_id = 123456789012\nsso_role_name = \(role)\nregion = us-east-1\n\n"
        }
        let config = root.appendingPathComponent("aws-fixture/config")
        try Data((section("alpha", role: "ReadOnly", session: "team") + section("beta", role: "Developer", session: "team") + section("other", role: "Audit", session: "other-team") +
            "[profile legacy]\nsso_start_url = https://legacy.awsapps.com/start\nsso_region = us-east-1\nsso_account_id = 123456789012\nsso_role_name = Legacy\n\n" +
            "[sso-session team]\nsso_start_url = https://example.awsapps.com/start\nsso_region = us-east-1\n\n[sso-session other-team]\nsso_start_url = https://example.awsapps.com/start\nsso_region = us-east-1\n").utf8).write(to: config)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        let cache = root.appendingPathComponent(".aws/sso/cache")
        try files.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        func cacheFile(_ session: String) -> URL {
            cache.appendingPathComponent(Insecure.SHA1.hash(data: Data(session.utf8)).map { String(format: "%02x", $0) }.joined() + ".json")
        }
        func writeToken(_ session: String) throws {
            let value: [String: Any] = ["accessToken": "tdb-test-sso-token", "refreshToken": "tdb-test-refresh-token", "startUrl": "https://example.awsapps.com/start",
                                        "region": "us-east-1", "expiresAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))]
            try JSONSerialization.data(withJSONObject: value).write(to: cacheFile(session))
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheFile(session).path)
        }
        try writeToken("team"); try writeToken("other-team")
        // Issued role credentials cached by AWS CLI must survive a restart.
        let roleCache = root.appendingPathComponent(".aws/cli/cache")
        try files.createDirectory(at: roleCache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let roleFile = roleCache.appendingPathComponent("synthetic-role.json")
        let roleBytes = Data(#"{"ProviderType":"sso","Credentials":{"AccessKeyId":"tdb-test-role-cache"}}"#.utf8)
        try roleBytes.write(to: roleFile)
        var service = SharedAWSService(root: root)
        func request(_ operation: String, _ payload: [String: Any] = [:]) throws -> [String: Any] {
            var response: [String: Any]?
            service.handle(operation, payload: payload) { response = $0 }
            let deadline = Date().addingTimeInterval(10)
            while response == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            guard let response else { throw PeerFailure("The synthetic AWS session operation did not finish.") }
            return response
        }
        func waitFor(_ condition: ([String: Any]) -> Bool) throws -> [String: Any] {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                let catalog = try request("aws.catalog")
                if condition(catalog) { return catalog }
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            throw PeerFailure("A synthetic AWS session did not reach its expected state.")
        }
        func waitForFile(_ url: URL) throws -> Bool {
            let deadline = Date().addingTimeInterval(5)
            while !files.fileExists(atPath: url.path) && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            return files.fileExists(atPath: url.path)
        }
        func sessions(_ catalog: [String: Any]) -> [[String: Any]] { catalog["ssoSessions"] as? [[String: Any]] ?? [] }
        func team(_ catalog: [String: Any]) -> [String: Any] { sessions(catalog).first { $0["name"] as? String == "team" } ?? [:] }
        func state(_ catalog: [String: Any], _ id: String) -> String? { (catalog["sourceChecks"] as? [String: [String: Any]])?[id]?["state"] as? String }
        func secretFree(_ catalog: [String: Any]) throws -> Bool {
            let text = String(decoding: try JSONSerialization.data(withJSONObject: catalog), as: UTF8.self)
            return !["tdb-test-sso-token", "tdb-test-refresh", "accessToken", "refreshToken", "tdb-test-role-cache", "tdb-test-sandbox", "tdb-test-secret", "tdb-test-session"].contains { text.contains($0) }
        }
        func sandboxes() throws -> [String] { try files.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("aws-restart-") } }
        let discovered = try request("aws.catalog")["profiles"] as! [[String: Any]]
        let ids = Dictionary(uniqueKeysWithValues: discovered.map { ($0["name"] as! String, $0["id"] as! String) })
        let alpha = ids["alpha"]!, beta = ids["beta"]!, other = ids["other"]!, legacy = ids["legacy"]!

        // Catalog contract: one entry per session, sorted by name, metadata only.
        let initial = try request("aws.catalog")
        try check(sessions(initial).map { $0["name"] as? String ?? "?" } == ["", "other-team", "team"])
        let teamID = team(initial)["id"] as? String ?? ""
        try check(teamID.count == 64 && team(initial)["profileIds"] as? [String] == [alpha, beta].sorted())
        try check(team(initial)["state"] as? String == "signedIn" && team(initial)["canRestart"] as? Bool == true)
        try check(team(initial)["startURL"] as? String == "https://example.awsapps.com/start")
        try check(team(initial)["duration"] as? Double == SharedAWSSessionRecord.defaultDuration && team(initial)["durationSource"] as? String == "default")
        try check(team(initial)["signedInAt"] == nil && team(initial)["expectedEnd"] == nil && team(initial)["endedAt"] == nil)
        let legacyEntry = sessions(initial).first { $0["name"] as? String == "" } ?? [:]
        try check(legacyEntry["state"] as? String == "signedOut" && legacyEntry["canRestart"] as? Bool == false && legacyEntry["profileIds"] as? [String] == [legacy])
        let authentication = initial["authentication"] as? [String: [String: Any]] ?? [:]
        try check(authentication[alpha]?["sessionId"] as? String == teamID && authentication[beta]?["sessionId"] as? String == teamID)
        try check(authentication[other]?["sessionId"] as? String != nil && authentication[other]?["sessionId"] as? String != teamID)
        try check(try secretFree(initial))
        try check(try request("aws.source.enable", ["profileId": alpha])["error"] == nil)
        _ = try waitFor { state($0, alpha) == "ready" }

        // A bare refresh failure is a network failure when OIDC is
        // unreachable, and a confirmed session end when it is reachable.
        let failure = root.appendingPathComponent("check-failure")
        let unreachable = root.appendingPathComponent("aws-fixture/sso-unreachable")
        try Data("refresh".utf8).write(to: failure); try Data().write(to: unreachable)
        try check(try request("aws.check", ["profileId": beta, "manual": true])["accepted"] as? Bool == true)
        let offline = try waitFor { state($0, beta) == "networkUnavailable" }
        try check(team(offline)["state"] as? String == "signedIn" && team(offline)["endedAt"] == nil)
        try files.removeItem(at: unreachable)
        try check(try request("aws.check", ["profileId": beta, "manual": true])["accepted"] as? Bool == true)
        let ended = try waitFor { state($0, beta) == "signInRequired" }
        try check(team(ended)["state"] as? String == "signedOut" && team(ended)["endedAt"] is Double && team(ended)["canRestart"] as? Bool == false)
        // Without a known fresh start, an observed end teaches nothing.
        try check(team(ended)["durationSource"] as? String == "default")
        try files.removeItem(at: failure)

        // Signing in after a confirmed end starts a fresh, full session.
        let beforeSignIn = Date().timeIntervalSince1970
        try check(try request("aws.signIn.start", ["profileId": beta])["accepted"] as? Bool == true)
        let fresh = try waitFor { $0["signInProfile"] as? String == "" && state($0, alpha) == "ready" && state($0, beta) == "ready" }
        var firstStart = team(fresh)["signedInAt"] as? Double ?? 0
        try check(firstStart >= beforeSignIn && team(fresh)["expectedEnd"] as? Double == firstStart + SharedAWSSessionRecord.defaultDuration)
        try check(team(fresh)["endedAt"] == nil && team(fresh)["state"] as? String == "signedIn")
        // Signing in while that session is active reuses it, so its start
        // and expected end do not move.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        try check(try request("aws.signIn.start", ["profileId": beta])["accepted"] as? Bool == true)
        let reused = try waitFor { $0["signInProfile"] as? String == "" && state($0, alpha) == "ready" && state($0, beta) == "ready" }
        try check(team(reused)["signedInAt"] as? Double == firstStart && team(reused)["state"] as? String == "signedIn")
        // A deliberate sign-out removes the token cache. Ending that way says
        // nothing about the session length, so nothing is learned.
        try files.removeItem(at: cacheFile("team"))
        try Data("auth".utf8).write(to: failure)
        try check(try request("aws.refresh", ["profileId": beta])["accepted"] as? Bool == true)
        let signedOutByUser = try waitFor { state($0, beta) == "signInRequired" }
        try check(team(signedOutByUser)["durationSource"] as? String == "default" && team(signedOutByUser)["duration"] as? Double == SharedAWSSessionRecord.defaultDuration && team(signedOutByUser)["state"] as? String == "signedOut")
        try files.removeItem(at: failure)
        try check(try request("aws.signIn.start", ["profileId": beta])["accepted"] as? Bool == true)
        let resumed = try waitFor { $0["signInProfile"] as? String == "" && state($0, alpha) == "ready" && state($0, beta) == "ready" && team($0)["state"] as? String == "signedIn" }
        firstStart = team(resumed)["signedInAt"] as? Double ?? 0
        try check(firstStart > 0 && team(resumed)["endedAt"] == nil)

        // A confirmed end of a fresh session shortens the expected duration
        // to the observed upper bound, in whole 15 minute steps.
        try Data("auth".utf8).write(to: failure)
        try check(try request("aws.refresh", ["profileId": beta])["accepted"] as? Bool == true)
        let learned = try waitFor { state($0, beta) == "signInRequired" }
        try check(team(learned)["duration"] as? Double == SharedAWSSessionRecord.minimumDuration && team(learned)["durationSource"] as? String == "learned")
        try check(team(learned)["expectedEnd"] as? Double == firstStart + SharedAWSSessionRecord.minimumDuration)
        let endedAt = team(learned)["endedAt"] as? Double ?? 0
        try check(endedAt >= firstStart && team(learned)["state"] as? String == "signedOut")
        try files.removeItem(at: failure)

        // A current token written after the end, as by `aws sso login` in a
        // terminal, is a new session. Enrolled profiles renew from it.
        try Data("external".utf8).write(to: root.appendingPathComponent("generation"))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        try writeToken("team")
        let external = try waitFor { team($0)["state"] as? String == "signedIn" }
        let modified = ((try files.attributesOfItem(atPath: cacheFile("team").path)[.modificationDate] as? Date)?.timeIntervalSince1970) ?? 0
        let externalStart = team(external)["signedInAt"] as? Double ?? 0
        try check(abs(externalStart - modified) < 0.01 && externalStart > endedAt)
        try check(team(external)["endedAt"] == nil && state(external, beta) != "signInRequired")
        try check(team(external)["expectedEnd"] as? Double == externalStart + SharedAWSSessionRecord.minimumDuration)
        func renewed(_ id: String, _ key: String) throws -> Bool {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if (try request("aws.credentials", ["profileId": id])["credentials"] as? [String: Any])?["AccessKeyId"] as? String == key { return true }
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            return false
        }
        try check(try renewed(alpha, "tdb-test-access-key-external") && renewed(beta, "tdb-test-access-key-external"))
        _ = try waitFor { state($0, alpha) == "ready" && state($0, beta) == "ready" }

        // A custom duration is authoritative. Evidence never overrides it,
        // and resetting returns to the AWS default.
        try check(try request("aws.session.configure", ["sessionId": teamID, "duration": 3600])["error"] == nil)
        let custom = try request("aws.catalog")
        try check(team(custom)["duration"] as? Double == 3600 && team(custom)["durationSource"] as? String == "custom")
        try check(team(custom)["expectedEnd"] as? Double == externalStart + 3600)
        try Data("auth".utf8).write(to: failure)
        try check(try request("aws.refresh", ["profileId": beta])["accepted"] as? Bool == true)
        let customEnded = try waitFor { state($0, beta) == "signInRequired" }
        try check(team(customEnded)["duration"] as? Double == 3600 && team(customEnded)["durationSource"] as? String == "custom" && team(customEnded)["endedAt"] is Double)
        try files.removeItem(at: failure)
        let invalid: [[String: Any]] = [["sessionId": teamID, "duration": 899], ["sessionId": teamID, "duration": 7_776_001], ["sessionId": teamID, "duration": "3600"],
                                        ["sessionId": teamID, "duration": true], ["sessionId": teamID, "duration": -900], ["sessionId": "team", "duration": 3600],
                                        ["duration": 3600], ["sessionId": String(repeating: "a", count: 64), "duration": 3600]]
        for payload in invalid { try check(try request("aws.session.configure", payload)["error"] != nil) }
        try check(team(try request("aws.catalog"))["duration"] as? Double == 3600)
        try check(try request("aws.session.configure", ["ssoSessionId": teamID, "duration": 7_776_000])["error"] == nil)
        try check(team(try request("aws.catalog"))["duration"] as? Double == 7_776_000)
        try check(try request("aws.session.configure", ["sessionId": teamID, "duration": 0])["error"] == nil)
        let reset = try request("aws.catalog")
        try check(team(reset)["duration"] as? Double == SharedAWSSessionRecord.defaultDuration && team(reset)["durationSource"] as? String == "default")
        try check(try request("aws.session.configure", ["sessionId": teamID, "duration": 5400])["error"] == nil)
        try check(try request("aws.session.configure", ["sessionId": teamID])["error"] == nil)
        try check(team(try request("aws.catalog"))["durationSource"] as? String == "default")
        // Records persist, and documents from before session tracking decode.
        let serviceFile = root.appendingPathComponent("aws-service.json")
        let saved = try JSONDecoder().decode(SharedAWSLocalDocument.self, from: Data(contentsOf: serviceFile))
        try check(saved.sessions?[teamID]?.signedInAt == externalStart && saved.sessions?[teamID]?.durationSource == "default")
        try check(try JSONDecoder().decode(SharedAWSLocalDocument.self, from: Data(#"{"sources":{}}"#.utf8)).sessions == nil)
        try check(try JSONDecoder().decode(SharedAWSSessionRecord.self, from: Data(#"{"signedInAt":5}"#.utf8)) == { var r = SharedAWSSessionRecord(); r.signedInAt = 5; return r }())
        try check(!String(decoding: try Data(contentsOf: serviceFile), as: UTF8.self).contains("tdb-test-sso-token"))
        service = SharedAWSService(root: root)
        try check(team(try request("aws.catalog"))["signedInAt"] as? Double == externalStart)

        // Restart: reach signed in again, then validate restart inputs.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        try writeToken("team")
        let ready = try waitFor { team($0)["state"] as? String == "signedIn" }
        let readyStart = team(ready)["signedInAt"] as? Double ?? 0
        try check(team(ready)["canRestart"] as? Bool == true)
        for payload: [String: Any] in [["profileId": beta, "restart": "yes"], ["profileId": beta, "restart": 1], ["profileId": legacy, "restart": true]] {
            try check(try request("aws.signIn.start", payload)["error"] != nil)
        }
        try check(try request("aws.catalog")["signInProfile"] as? String == "")
        let restartCalls = root.appendingPathComponent("restart-calls.jsonl")
        func calls() throws -> [[String: Any]] {
            guard files.fileExists(atPath: restartCalls.path) else { return [] }
            return try String(contentsOf: restartCalls, encoding: .utf8).split(separator: "\n").compactMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }
        let otherBytes = try Data(contentsOf: cacheFile("other-team"))
        let teamName = cacheFile("team").lastPathComponent
        // Foundation's symlink resolution drops /private, unlike Python's.
        let resolvedRoot = realpath(root.path, nil).map { pointer in defer { free(pointer) }; return String(cString: pointer) } ?? root.path

        // Cancel while the restart is ending the old session: the sandbox is
        // removed, logout never runs, and the real token cache is untouched.
        let restartDelay = root.appendingPathComponent("restart-delay")
        try Data().write(to: restartDelay)
        let teamBytes = try Data(contentsOf: cacheFile("team"))
        try check(try request("aws.signIn.start", ["profileId": beta, "restart": true])["accepted"] as? Bool == true)
        try check(try waitForFile(root.appendingPathComponent("restart-started")))
        let restarting = try request("aws.catalog")
        try check(restarting["phase"] as? String == SharedAWSService.restartPhase)
        try check(team(restarting)["state"] as? String == "signingIn" && team(restarting)["canRestart"] as? Bool == false)
        let pending = try sandboxes()
        try check(pending.count == 1)
        let sandbox = root.appendingPathComponent(pending.first ?? "missing")
        try check((try files.attributesOfItem(atPath: sandbox.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        try check(try files.contentsOfDirectory(atPath: sandbox.appendingPathComponent(".aws/sso/cache").path) == [teamName])
        try check((try files.attributesOfItem(atPath: sandbox.appendingPathComponent(".aws/sso/cache/" + teamName).path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try check(try request("aws.signIn.cancel", ["profileId": beta])["accepted"] as? Bool == true)
        try check(!files.fileExists(atPath: sandbox.path))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        try check(try sandboxes().isEmpty && !files.fileExists(atPath: sandbox.path))
        try check(try calls().map { $0["operation"] as? String ?? "" } == ["configure export-credentials"])
        try check(try Data(contentsOf: cacheFile("team")) == teamBytes)
        let cancelled = try request("aws.catalog")
        try check(cancelled["signInProfile"] as? String == "" && team(cancelled)["state"] as? String == "signedIn" && team(cancelled)["signedInAt"] as? Double == readyStart)
        try files.removeItem(at: restartDelay)
        try files.removeItem(at: root.appendingPathComponent("restart-started"))
        try files.removeItem(at: restartCalls)

        // A completed restart logs out only this session from a sandbox,
        // then signs in with the real HOME, so the new session is fresh.
        let fixtureCalls = root.appendingPathComponent("fixture-calls.jsonl")
        func loginCalls() throws -> [[String: Any]] {
            try String(contentsOf: fixtureCalls, encoding: .utf8).split(separator: "\n").compactMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }.filter { $0["operation"] as? String == "sso" }
        }
        let loginsBefore = try loginCalls().count
        let beforeRestart = Date().timeIntervalSince1970
        try check(try request("aws.signIn.start", ["profileId": beta, "restart": true])["accepted"] as? Bool == true)
        let restarted = try waitFor { $0["signInProfile"] as? String == "" && team($0)["state"] as? String == "signedIn" }
        let steps = try calls()
        try check(steps.map { $0["operation"] as? String ?? "" } == ["configure export-credentials", "sso logout", "logout-api"])
        let sandboxHome = steps.first?["home"] as? String ?? ""
        try check(sandboxHome.hasPrefix(resolvedRoot + "/aws-restart-") && steps[1]["home"] as? String == sandboxHome)
        try check(steps[0]["files"] as? [String] == [teamName] && steps[1]["files"] as? [String] == [teamName])
        try check(steps[2]["refreshed"] as? [Bool] == [true])
        try check(try sandboxes().isEmpty)
        try check(try Data(contentsOf: cacheFile("other-team")) == otherBytes)
        try check(try Data(contentsOf: roleFile) == roleBytes)
        try check(files.fileExists(atPath: cacheFile("team").path) && (try Data(contentsOf: cacheFile("team"))) != teamBytes)
        let logins = try loginCalls()
        try check(logins.count == loginsBefore + 1 && logins.last?["session"] as? String == "team")
        let restartStart = team(restarted)["signedInAt"] as? Double ?? 0
        try check(restartStart >= beforeRestart && restartStart > readyStart && team(restarted)["endedAt"] == nil)
        try check(try request("aws.credentials", ["profileId": alpha])["credentials"] is [String: Any])
        try check(try secretFree(restarted))
        _ = try waitFor { state($0, alpha) == "ready" && state($0, beta) == "ready" }
        try files.removeItem(at: restartCalls)

        // When the old session cannot be ended, sign-in still proceeds but
        // reuses it, so its known start time is kept.
        try Data().write(to: root.appendingPathComponent("restart-refresh-fail"))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        try check(try request("aws.signIn.start", ["profileId": beta, "restart": true])["accepted"] as? Bool == true)
        let unended = try waitFor { $0["signInProfile"] as? String == "" && team($0)["state"] as? String == "signedIn" }
        try check(try calls().map { $0["operation"] as? String ?? "" } == ["configure export-credentials"])
        try check(team(unended)["signedInAt"] as? Double == restartStart && (try sandboxes()).isEmpty)
        try check(try Data(contentsOf: cacheFile("other-team")) == otherBytes && (try Data(contentsOf: roleFile)) == roleBytes)
        try files.removeItem(at: root.appendingPathComponent("restart-refresh-fail"))
        try files.removeItem(at: restartCalls)
        _ = try waitFor { state($0, alpha) == "ready" && state($0, beta) == "ready" }

        // A failed logout also falls back to an ordinary, reused sign-in.
        try Data().write(to: root.appendingPathComponent("restart-logout-fail"))
        try check(try request("aws.signIn.start", ["profileId": beta, "restart": true])["accepted"] as? Bool == true)
        let notLoggedOut = try waitFor { $0["signInProfile"] as? String == "" && team($0)["state"] as? String == "signedIn" }
        try check(try calls().map { $0["operation"] as? String ?? "" } == ["configure export-credentials", "sso logout"])
        try check(team(notLoggedOut)["signedInAt"] as? Double == restartStart && (try sandboxes()).isEmpty)
        try files.removeItem(at: root.appendingPathComponent("restart-logout-fail"))
        return count
    }
}
