import Foundation
import Darwin

// This service runs in the session host. Secret-bearing callbacks stay on its
// serial work queue and never enter terminal scrollback, receipts or UI state.
final class SharedAccountService {
    private let queue = DispatchQueue(label: "com.terminaldb.accounts")
    private var signIn: SharedAccountSignIn?
    private var phase = ""
    var changed: (() -> Void)?

    func handle(_ operation: String, payload: [String: Any], audit: Data? = nil, authenticate: Bool = false, completion: @escaping ([String: Any]) -> Void) {
        queue.async {
            do {
                if authenticate && operation != "accounts.catalog" {
                    guard let audit, SharedAccountCodeIdentity.allowsLocalManagement(audit: audit) else {
                        throw PeerFailure("Only the installed TerminalDB app and its networking helper can manage shared sign-ins.")
                    }
                }
                let store = SharedAccountStore()
                if let catalog = payload["localCatalog"] as? [[String: String]], try store.updateDirectory(catalog) { self.notify() }
                var reply: [String: Any] = [:]
                switch operation {
                case "accounts.check": reply = ["accepted": true]
                case "accounts.catalog":
                    reply = ["accounts": TDBSharedAccounts.catalog(), "signInPhase": self.phase]
                case "accounts.sync.export": reply = ["bundle": try store.exportBundle()]
                case "accounts.sync.digest":
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                    let doc = try store.load()
                    let content: [String: Any] = ["accounts": try JSONSerialization.jsonObject(with: encoder.encode(doc.accounts)),
                                                  "directory": try JSONSerialization.jsonObject(with: encoder.encode(doc.directory ?? [:]))]
                    reply = ["digest": PeerProtocol.fingerprint(try JSONSerialization.data(withJSONObject: content, options: [.sortedKeys]))]
                case "accounts.sync.import":
                    guard let bundle = payload["bundle"] as? [String: Any] else { throw PeerFailure("The account transfer is incomplete.") }
                    try store.importBundle(bundle); self.notify(); reply = ["accepted": true]
                case "accounts.remove":
                    guard let id = payload["accountId"] as? String else { throw PeerFailure("Choose an account first.") }
                    try store.remove(id); self.notify(); reply = ["accepted": true]
                case "accounts.signIn.cancel":
                    self.signIn?.cancel(); self.signIn = nil; self.phase = ""; reply = ["accepted": true]
                case "accounts.signIn.start":
                    guard self.signIn == nil else { throw PeerFailure("Complete or cancel the sign-in already open in your browser.") }
                    let job = try SharedAccountSignIn(payload: payload, queue: self.queue)
                    self.signIn = job; self.phase = "Complete sign-in in your browser. Choose the account shown here."
                    job.finished = { [weak self, weak job] token in
                        guard let self, let job, self.signIn === job else { return }
                        defer { self.signIn = nil; self.notify() }
                        do {
                            guard let token else { throw PeerFailure("Sign-in did not finish. Try again from Accounts & Usage.") }
                            _ = try store.save(label: job.label, email: job.email, organization: job.organization,
                                               plan: job.plan, token: token,
                                               expires: Date().addingTimeInterval(364 * 86400).timeIntervalSince1970,
                                               binding: job.binding)
                            self.phase = "Sign-in saved. Your approved Macs will receive it when connected."
                        } catch { self.phase = "The reusable sign-in could not be saved. Unlock Keychain and try again." }
                    }
                    try job.start(); reply = ["accepted": true]
                default: throw PeerFailure("This account operation is unsupported.")
                }
                DispatchQueue.main.async { completion(reply) }
            } catch {
                if operation == "accounts.signIn.start" { self.signIn?.cancel(); self.signIn = nil }
                // Never interpolate process output or credential-bearing data.
                let detail = (error as? PeerFailure)?.message ?? "The shared account operation could not finish. Try again."
                DispatchQueue.main.async { completion(["error": detail]) }
            }
        }
    }
    private func notify() { DispatchQueue.main.async { self.changed?() } }
}

private final class SharedAccountSignIn {
    let label: String, email: String, organization: String, plan: String
    let binding: String?
    private let executable: String
    private let directory: String
    private let queue: DispatchQueue
    private var process: Process?
    private var reader: DispatchSourceRead?
    private var descriptor: Int32 = -1
    private var buffer = Data()
    private var completed = false
    var finished: ((Data?) -> Void)?

    init(payload: [String: Any], queue: DispatchQueue) throws {
        label = payload["label"] as? String ?? ""
        email = payload["email"] as? String ?? ""
        organization = payload["organization"] as? String ?? ""
        plan = payload["plan"] as? String ?? ""
        binding = payload["binding"] as? String
        executable = payload["executable"] as? String ?? ""
        directory = payload["configDirectory"] as? String ?? ""
        self.queue = queue
        guard !label.isEmpty, label.utf8.count <= 160, email.contains("@"), email.utf8.count <= 320,
              !email.contains(where: \.isWhitespace), organization.utf8.count <= 160, plan.utf8.count <= 80,
              executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable),
              directory.hasPrefix("/"), directory.utf8.count <= 2048 else {
            throw PeerFailure("Enter an account name and email, and install Claude Code on this Mac first.")
        }
        guard SharedAccountCodeIdentity.isClaude(executable) else {
            throw PeerFailure("Shared sign-ins require Anthropic’s signed native Claude Code. Install it from code.claude.com, then try again.")
        }
    }
    func start() throws {
        var master: Int32 = -1, slave: Int32 = -1
        var size = winsize(ws_row: 40, ws_col: 4096, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw PeerFailure("The Claude sign-in could not start.") }
        descriptor = master
        fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        let task = Process(); task.executableURL = URL(fileURLWithPath: executable); task.arguments = ["setup-token"]
        var environment = ProcessInfo.processInfo.environment
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_BASE_URL",
                    "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"] { environment.removeValue(forKey: key) }
        environment["CLAUDE_CONFIG_DIR"] = directory
        environment["TERM"] = "xterm-256color"; environment["NO_COLOR"] = "1"
        task.environment = environment
        task.standardInput = terminal; task.standardOutput = terminal; task.standardError = terminal
        task.terminationHandler = { [weak self] _ in self?.queue.async { self?.drain(); self?.finish(nil) } }
        process = task
        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { Darwin.close(master) }
        reader = source; source.resume()
        do { try task.run() } catch { cancel(); throw PeerFailure("Claude Code could not start its sign-in flow.") }
        DispatchQueue.global().asyncAfter(deadline: .now() + 600) { [weak self] in self?.queue.async { self?.cancel() } }
    }
    private func drain() {
        guard descriptor >= 0, !completed else { return }
        var bytes = [UInt8](repeating: 0, count: 4096)
        for _ in 0..<16 {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            guard count > 0 else { break }
            buffer.append(contentsOf: bytes.prefix(count))
            // Bound all captured output. No output is published to a viewer.
            if buffer.count > 65536 { buffer.removeFirst(buffer.count - 65536) }
            let text = String(decoding: buffer, as: UTF8.self)
            let fixture = ProcessInfo.processInfo.environment["TERMINALDB_PEER_QA"] == "1" && ProcessInfo.processInfo.environment["TERMINALDB_PEER_EPHEMERAL_IDENTITY"] == "1"
            let pattern = fixture ? #"tdb-test-[A-Za-z0-9_-]{40,2048}"# : #"sk-ant-oat[0-9]{2}-[A-Za-z0-9_-]{40,2048}"#
            if let range = text.range(of: pattern, options: .regularExpression) {
                let end = range.upperBound
                // Wait for a delimiter; a read can split the token itself.
                if end < text.endIndex {
                    finish(Data(text[range].utf8)); return
                }
            }
        }
    }
    private func finish(_ token: Data?) {
        guard !completed else { return }; completed = true
        buffer.resetBytes(in: 0..<buffer.count); buffer.removeAll()
        reader?.cancel(); reader = nil; descriptor = -1
        if process?.isRunning == true { process?.terminate() }
        let base = PeerPaths.root.appendingPathComponent("sign-ins/").path
        if directory.hasPrefix(base), UUID(uuidString: URL(fileURLWithPath: directory).lastPathComponent) != nil {
            try? FileManager.default.removeItem(atPath: directory)
        }
        let callback = finished; finished = nil; callback?(token)
    }
    func cancel() { finish(nil) }
}

enum PeerAccountHostRPC {
    static func call(_ operation: String, payload: [String: Any] = [:], completion: @escaping ([String: Any]) -> Void) {
        do {
            let connection = try PeerLocalConnection.connect("host")
            let request = UUID().uuidString
            var completed = false
            func finish(_ result: [String: Any]) {
                guard !completed else { return }; completed = true
                connection.receive = nil; connection.disconnected = nil; connection.close(); completion(result)
            }
            connection.receive = { message in
                if message["type"] as? String == "ready" {
                    var body = payload; body["type"] = "request"; body["requestId"] = request; body["operation"] = operation
                    connection.send(body)
                } else if message["requestId"] as? String == request { finish(message) }
            }
            connection.disconnected = { finish(["error": "The local account service is unavailable."]) }
            connection.start()
            connection.send(["type": "hello", "version": PeerProtocol.version, "clientId": UUID().uuidString,
                             "secret": try String(contentsOf: PeerPaths.file("host.secret"), encoding: .utf8)])
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { finish(["error": "The local account service did not respond."]) }
        } catch { completion(["error": "The local account service is unavailable."]) }
    }
}

extension TDBSharedAccounts {
    @objc public static var launcherPath: String {
        if Bundle.main.bundleIdentifier == "com.terminaldb.session-host" { return Bundle.main.executablePath ?? "" }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LoginItems/TerminalDBSessionHost.app/Contents/MacOS/TerminalDBSessionHost").path
    }
    // Runs before AppKit startup. Secrets appear only in the unmodified Claude
    // process environment, never its arguments, a shell script or history.
    @objc public static func runLauncherIfRequested() -> Int32 {
        let args = ProcessInfo.processInfo.arguments
        guard args.count > 1, args[1] == "--claude-launch" else { return -1 }
        guard args.count >= 5, args[3] == "--", args[4].hasPrefix("/"), FileManager.default.isExecutableFile(atPath: args[4]) else { return 64 }
        do {
            if !args[2].isEmpty {
                guard SharedAccountCodeIdentity.isClaude(args[4]) else {
                    fputs("TerminalDB: shared sign-ins require Anthropic’s signed native Claude Code.\n", stderr); return 1
                }
                guard args[2].count == 64, args[2].allSatisfy({ $0.isHexDigit }) else { return 64 }
                let data = try SharedAccountStore().token(for: args[2])
                guard let token = String(data: data, encoding: .utf8) else { return 65 }
                for name in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"] { unsetenv(name) }
                setenv("CLAUDE_CODE_OAUTH_TOKEN", token, 1)
            }
            let command = Array(args.dropFirst(4))
            let strings = command.map { strdup($0) } + [nil]
            defer { for p in strings { if let p { free(p) } } }
            strings.withUnsafeBufferPointer { _ = execv(args[4], $0.baseAddress!) }
            return 127
        } catch {
            fputs("TerminalDB: the shared Claude sign-in is unavailable. Open Accounts & Usage to renew it or unlock Keychain.\n", stderr)
            return 1
        }
    }
}
