import Foundation
import AppKit

@objc(TDBSessionServer)
public final class TDBSessionServer: NSObject {
    // Host-side adapter only. The networking process never owns a PTY or a
    // provider credential. All execution and terminal state live here.
    @objc public var requestHandler: ((NSDictionary, @escaping (NSDictionary) -> Void) -> Void)?
    private var listener: PeerLocalListener?
    private var clients: [String: PeerHostClient] = [:]
    private var leases: [String: PeerControlLease] = [:]
    private let receipts = PeerReceipts()
    private var inFlight: Set<String> = []
    private let readable: Set<String> = ["session.list", "session.attach", "session.snapshot", "host.state", "receipt", "ledger.query", "product.list", "project.files", "project.preview", "health.ping"]

    @objc public func start() throws {
        let listener = try PeerLocalListener(name: "host")
        listener.accepted = { [weak self] connection, hello in self?.accept(connection, hello: hello) }
        self.listener = listener
    }

    private func accept(_ connection: PeerLocalConnection, hello: [String: Any]) {
        let client = PeerHostClient(connection: connection, hello: hello)
        for previous in clients.values where previous.principal == client.principal {
            previous.superseded = true
            previous.connection.close()
            for session in leases.keys where leases[session]?.owner == previous.principal {
                leases[session]?.release(previous.principal)
                publishControl(session)
            }
        }
        clients[connection.id] = client
        connection.receive = { [weak self, weak client] message in
            guard let self, let client else { return }
            self.handle(message, client: client)
        }
        let originalClose = connection.disconnected
        connection.disconnected = { [weak self, weak client] in
            originalClose?()
            guard let self, let client else { return }
            self.clients.removeValue(forKey: connection.id)
            guard !client.superseded else { return }
            for session in self.leases.keys where self.leases[session]?.owner == client.principal {
                self.leases[session]?.release(client.principal)
                self.publishControl(session)
            }
        }
        connection.send(["type": "ready", "version": PeerProtocol.version, "clientId": client.clientID, "hostClock": PeerClock.now])
    }

    private func handle(_ message: [String: Any], client: PeerHostClient) {
        guard !client.superseded else { client.connection.close(); return }
        guard message["type"] as? String == "request",
              let operation = message["operation"] as? String, operation.utf8.count <= 100,
              let requestID = message["requestId"] as? String, UUID(uuidString: requestID) != nil else {
            client.connection.close(); return
        }
        if let cached = receipts.result(principal: client.principal, request: requestID) {
            client.connection.send(cached); return
        }
        let receiptKey = client.principal + ":" + requestID
        guard !inFlight.contains(receiptKey) else { return }
        guard inFlight.count < 512 else { client.connection.close(); return }
        inFlight.insert(receiptKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.inFlight.remove(receiptKey) }
        let session = message["sessionId"] as? String ?? ""
        let reply: ([String: Any]) -> Void = { [weak self, weak client] payload in
            guard let self else { return }
            self.inFlight.remove(receiptKey)
            guard let client else { return }
            var result = payload
            result["type"] = "reply"; result["requestId"] = requestID; result["hostClock"] = PeerClock.now
            if !self.readable.contains(operation) { self.receipts.remember(principal: client.principal, request: requestID, result: result) }
            client.connection.send(result)
        }
        if operation == "receipt" {
            reply(["result": receipts.result(principal: client.principal, request: message["receiptId"] as? String ?? "") ?? [:]])
            return
        }
        if operation == "health.ping" { reply(["accepted": true]); return }
        if operation == "session.detach" {
            client.sessions.remove(session)
            leases[session]?.release(client.principal)
            publishControl(session); reply(["accepted": true]); return
        }
        if operation == "control.acquire" {
            guard client.sessions.contains(session) else { reply(["error": "Open this session before taking control."]); return }
            if leases[session] == nil { leases[session] = PeerControlLease() }
            let generation = leases[session]!.acquire(client.principal)
            publishControl(session)
            reply(["accepted": true, "generation": generation]); return
        }
        if operation == "control.release" {
            leases[session]?.release(client.principal)
            publishControl(session); reply(["accepted": true]); return
        }
        if !readable.contains(operation) && operation != "session.create" {
            guard client.sessions.contains(session),
                  let generation = message["generation"] as? UInt64,
                  leases[session]?.allows(client.principal, generation: generation) == true else {
                reply(["error": "This view no longer controls the session. Choose Take Control.", "code": "control-required"]); return
            }
        }
        if operation == "terminal.input" {
            guard !client.blockedInput.contains(session) else { reply(["error": "This input stream stopped after a rejected batch. Review the terminal and reconnect.", "code": "input-blocked"]); return }
            let now = PeerClock.now
            guard let deadline = message["inputDeadline"] as? Double, deadline.isFinite,
                  deadline >= now, deadline <= now + 15 else {
                client.blockedInput.insert(session)
                reply(["error": "This input expired before reaching the shell. Review it before trying again.", "code": "input-expired"]); return
            }
            guard let sequence = message["inputSequence"] as? UInt64,
                  sequence == (client.inputSequences[session] ?? 0) + 1 else {
                client.blockedInput.insert(session)
                reply(["error": "The input stream has a gap. Reconnect before entering more text.", "code": "input-gap"]); return
            }
            client.inputSequences[session] = sequence
        }
        guard let handler = requestHandler else { reply(["error": "The session service is starting."]); return }
        var request = message
        request["principal"] = client.principal
        request["deliveryClientId"] = client.connection.id
        handler(request as NSDictionary) { [weak self, weak client] result in
            let apply = {
                guard let self, let client else { return }
                let result = result as? [String: Any] ?? [:]
                if operation == "terminal.input", result["error"] != nil { client.blockedInput.insert(session) }
                if result["error"] == nil {
                    if operation == "session.attach" || operation == "session.create" {
                        let id = result["sessionId"] as? String ?? session
                        client.sessions.insert(id)
                        if self.leases[id] == nil { self.leases[id] = PeerControlLease() }
                        if self.leases[id]?.owner == nil { _ = self.leases[id]?.acquire(client.principal) }
                        self.publishControl(id)
                        var attached = result
                        attached["generation"] = self.leases[id]?.generation ?? 0
                        attached["controlling"] = self.leases[id]?.owner == client.principal
                        reply(attached)
                        return
                    }
                    if operation == "session.end" {
                        self.publish(["type": "ended", "sessionId": session] as NSDictionary)
                        self.leases.removeValue(forKey: session)
                    }
                }
                reply(result)
            }
            if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
        }
    }

    private func publishControl(_ session: String) {
        for client in clients.values where client.sessions.contains(session) {
            client.connection.send(["type": "control", "sessionId": session,
                                    "generation": leases[session]?.generation ?? 0,
                                    "controlling": leases[session]?.owner == client.principal])
        }
    }

    @objc public func publishToClient(_ event: NSDictionary, clientID: String) {
        guard let message = event as? [String: Any], let client = clients[clientID],
              let session = message["sessionId"] as? String, client.sessions.contains(session) else { return }
        client.connection.send(message)
    }

    @objc public func publish(_ event: NSDictionary) {
        guard let message = event as? [String: Any] else { return }
        let session = message["sessionId"] as? String
        for client in clients.values where session == nil || client.sessions.contains(session!) {
            client.connection.send(message)
            if message["type"] as? String == "ended", let session {
                client.sessions.remove(session); client.inputSequences.removeValue(forKey: session)
            }
        }
        if message["type"] as? String == "ended", let session { leases.removeValue(forKey: session) }
    }
}

private final class PeerHostClient {
    let connection: PeerLocalConnection
    let clientID: String
    let principal: String
    var sessions: Set<String> = []
    var inputSequences: [String: UInt64] = [:]
    var blockedInput: Set<String> = []
    var superseded = false
    init(connection: PeerLocalConnection, hello: [String: Any]) {
        self.connection = connection
        clientID = (hello["clientId"] as? String).flatMap { UUID(uuidString: $0)?.uuidString } ?? UUID().uuidString
        // A broker's claim arrives only over the same-user, secret-protected
        // agent connection. Network clients never reach the local socket.
        if hello["role"] as? String == "peer", let peer = hello["peerId"] as? String,
           peer.count == 64, peer.allSatisfy({ $0.isHexDigit }) {
            principal = peer + ":" + clientID
        } else { principal = "local:" + clientID }
    }
}

enum PeerInputRecovery {
    private static func entries() -> [String: Double] {
        guard let data = try? Data(contentsOf: PeerPaths.file("uncertain-input.json")),
              let entries = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
        return entries
    }
    static func contains(_ key: String) -> Bool { entries()[key] != nil }
    static func set(_ key: String, uncertain: Bool) {
        var value = entries()
        if uncertain { value[key] = Date().timeIntervalSince1970 } else { value.removeValue(forKey: key) }
        if value.count > 4096, let oldest = value.min(by: { $0.value < $1.value })?.key { value.removeValue(forKey: oldest) }
        if let data = try? JSONEncoder().encode(value) { try? PeerPaths.save(data, name: "uncertain-input.json") }
    }
}

@objc(TDBSessionClient)
public final class TDBSessionClient: NSObject {
    @objc public var eventHandler: ((NSDictionary) -> Void)?
    @objc public private(set) var sessionID = ""
    @objc public private(set) var connected = false
    @objc public private(set) var controlling = false
    @objc public private(set) var ended = false
    @objc public private(set) var synchronizing = false
    @objc public private(set) var snapshotFailed = false
    @objc public private(set) var generation: UInt64 = 0
    @objc public var workstationID = ""
    @objc public var workstationName = "This Mac"
    @objc public private(set) var connectionPath = "This Mac"
    @objc public var agentManagement = false
    @objc public var privateSessionRequested = false
    let clientID = UUID().uuidString
    private var connection: PeerLocalConnection?
    private var callbacks: [String: (NSDictionary) -> Void] = [:]
    private var sequence: UInt64 = 0
    private var ready: (() -> Void)?
    private var connectionGeneration = 0
    private var reconnectAttempt = 0
    private var deliberatelyClosed = false
    private var lastConnectionError = ""
    private var pendingInput = 0
    private var stagedInput = Data()
    private var stagedGeneration: UInt64 = 0
    private var stagedDeadline = 0.0
    private var flushScheduled = false
    private var healthTimer: Timer?
    private var lastReceived = PeerClock.now
    private var hostClock = 0.0
    private var hostClockReceived = 0.0
    private var wakeObserver: NSObjectProtocol?
    @objc public private(set) var inputUncertain = false
    private var recoveryKey: String { (workstationID.isEmpty ? "local" : workstationID) + ":" + sessionID }
    private func markUncertain() {
        inputUncertain = true
        if !sessionID.isEmpty { PeerInputRecovery.set(recoveryKey, uncertain: true) }
    }

    public override init() {
        super.init()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard let self, !self.deliberatelyClosed else { return }; self.reconnect()
            }
    }
    deinit {
        healthTimer?.invalidate()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        connection?.close()
    }

    @objc public func connect(completion: @escaping (NSDictionary) -> Void) {
        deliberatelyClosed = false
        ready = { completion(["connected": true]) }
        open()
    }

    private func open() {
        guard !deliberatelyClosed else { return }
        connectionGeneration += 1
        let current = connectionGeneration
        let name = workstationID.isEmpty && !agentManagement ? "host" : "peer"
        do {
            let connection = try PeerLocalConnection.connect(name)
            self.connection = connection
            connection.receive = { [weak self] message in
                guard let self, self.connectionGeneration == current else { return }
                self.receive(message)
            }
            connection.disconnected = { [weak self] in
                guard let self, self.connectionGeneration == current else { return }
                self.lostConnection()
            }
            let secret = try String(contentsOf: PeerPaths.file(name + ".secret"), encoding: .utf8)
            connection.start()
            connection.send(["type": "hello", "version": PeerProtocol.version, "secret": secret,
                             "clientId": clientID, "role": "native"])
        } catch { lostConnection() }
    }

    private func receive(_ message: [String: Any]) {
        lastReceived = PeerClock.now
        if let clock = message["hostClock"] as? Double, clock.isFinite {
            hostClock = clock; hostClockReceived = lastReceived
        }
        switch message["type"] as? String {
        case "ready":
            if !agentManagement && !workstationID.isEmpty && message["peerConnected"] as? Bool != true {
                connection?.send(["type": "connect", "peerId": workstationID, "clientId": clientID]); return
            }
            connected = true; reconnectAttempt = 0; lastConnectionError = ""
            hostClock = message["hostClock"] as? Double ?? 0
            hostClockReceived = PeerClock.now
            if !agentManagement && healthTimer == nil {
                healthTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                    guard let self, self.connected, PeerClock.now - self.lastReceived >= 5 else { return }
                    self.request("health.ping", payload: [:]) { [weak self] result in
                        guard let self else { return }
                        if result["error"] != nil && PeerClock.now - self.lastReceived > 10 { self.connection?.close() }
                    }
                }
            }
            connectionPath = message["connectionPath"] as? String ?? (workstationID.isEmpty ? "This Mac" : "Direct LAN")
            sequence = 0
            if !sessionID.isEmpty {
                synchronizing = true
                request("session.attach", payload: ["sessionId": sessionID]) { [weak self] result in
                    self?.applyAttachment(result)
                    self?.eventHandler?(["type": "reconnected"])
                }
            }
            let callback = ready; ready = nil; callback?()
            eventHandler?(["type": "connected"])
        case "reply":
            guard let request = message["requestId"] as? String else { return }
            let callback = callbacks.removeValue(forKey: request)
            callback?(message as NSDictionary)
        case "snapshot.end":
            synchronizing = false; snapshotFailed = false
            eventHandler?(message as NSDictionary)
        case "error":
            lastConnectionError = message["detail"] as? String ?? "The workstation connection failed."
            eventHandler?(["type": "connection-error", "detail": lastConnectionError])
        case "ended":
            ended = true; controlling = false
            PeerInputRecovery.set(recoveryKey, uncertain: false)
            eventHandler?(message as NSDictionary)
        case "input-failed":
            markUncertain()
            eventHandler?(["type": "input-uncertain", "detail": message["detail"] ?? "The shell stopped accepting input."])
        case "control":
            generation = message["generation"] as? UInt64 ?? 0
            controlling = message["controlling"] as? Bool ?? false
            eventHandler?(message as NSDictionary)
        default: eventHandler?(message as NSDictionary)
        }
    }

    @objc public func request(_ operation: String, payload: NSDictionary, completion: @escaping (NSDictionary) -> Void) {
        guard let connection, connected else { completion(["error": "The workstation is not connected."]); return }
        guard callbacks.count < 256 else { completion(["error": "The connection is busy. Wait for pending operations to finish."]); return }
        let id = UUID().uuidString
        var message = payload as? [String: Any] ?? [:]
        message["type"] = "request"; message["operation"] = operation; message["requestId"] = id
        message["sessionId"] = message["sessionId"] ?? sessionID
        message["generation"] = generation
        do { _ = try PeerProtocol.encode(message) }
        catch {
            let detail = "This action exceeds the supported message size or contains unsupported data. Reduce its size and try again."
            eventHandler?(["type": "operation-error", "detail": detail]); completion(["error": detail]); return
        }
        if operation == "session.snapshot" { synchronizing = true; snapshotFailed = false }
        callbacks[id] = { [weak self] result in
            if operation == "session.snapshot", result["error"] != nil { self?.synchronizing = false; self?.snapshotFailed = true }
            if let error = result["error"] as? String, operation != "health.ping" {
                self?.eventHandler?(["type": "operation-error", "detail": error])
            }
            completion(result)
        }
        connection.send(message)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, let callback = self.callbacks.removeValue(forKey: id) else { return }
            callback(["error": "Delivery is uncertain. This request was not automatically repeated.", "uncertain": true])
        }
    }

    @objc public func attach(_ session: String, completion: @escaping (NSDictionary) -> Void) {
        synchronizing = true
        request("session.attach", payload: ["sessionId": session]) { [weak self] result in
            self?.applyAttachment(result); completion(result)
        }
    }
    @objc public func create(_ directory: String, completion: @escaping (NSDictionary) -> Void) {
        synchronizing = true
        request("session.create", payload: ["directory": directory, "private": privateSessionRequested]) { [weak self] result in
            self?.applyAttachment(result); completion(result)
        }
    }
    private func applyAttachment(_ result: NSDictionary) {
        guard result["error"] == nil else {
            synchronizing = false; snapshotFailed = true
            if result["code"] as? String == "session-unavailable" { ended = true; controlling = false; eventHandler?(["type": "ended"]) }
            else { eventHandler?(["type": "operation-error", "detail": result["error"] ?? "The session is unavailable."]) }
            return
        }
        ended = false
        sessionID = result["sessionId"] as? String ?? sessionID
        inputUncertain = inputUncertain || PeerInputRecovery.contains(recoveryKey)
        generation = result["generation"] as? UInt64 ?? 0
        controlling = result["controlling"] as? Bool ?? false
        eventHandler?(["type": "attached", "state": result])
        if inputUncertain { eventHandler?(["type": "input-uncertain", "detail": "A previous view closed before input delivery was confirmed. Review the terminal before continuing; that input will not be repeated."]) }
    }
    @objc public func sendInput(_ data: Data) -> Bool {
        guard connected, controlling, !ended, !synchronizing, !snapshotFailed, !inputUncertain else { return false }
        guard stagedInput.count + data.count <= 4 * PeerProtocol.maximumFrame else {
            rejectStagedInput("This input was not queued because the connection is busy. Review the terminal before continuing; rejected text will not be repeated."); return false
        }
        if stagedInput.isEmpty {
            stagedGeneration = generation
            stagedDeadline = hostClock + (PeerClock.now - hostClockReceived) + 10
        }
        stagedInput.append(data); scheduleInputFlush()
        return true
    }
    private func scheduleInputFlush() {
        guard !flushScheduled, !stagedInput.isEmpty else { return }
        flushScheduled = true
        let connectionID = connectionGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.004) { [weak self] in
            guard let self, self.connectionGeneration == connectionID else { return }
            self.flushScheduled = false
            self.flushInput()
        }
    }
    private func rejectStagedInput(_ detail: String) {
        stagedInput.removeAll(keepingCapacity: false); markUncertain()
        eventHandler?(["type": "input-uncertain", "detail": detail])
    }
    private func flushInput() {
        guard !stagedInput.isEmpty else { return }
        guard connected, controlling, !inputUncertain, stagedGeneration == generation,
              hostClock + (PeerClock.now - hostClockReceived) <= stagedDeadline else {
            rejectStagedInput("Queued input expired or control changed before delivery. Review the terminal; that input was not repeated."); return
        }
        // Coalesce rapid key events, then preserve ordering in bounded chunks.
        // Backpressure pauses this queue instead of discarding a typing burst.
        while !stagedInput.isEmpty && pendingInput < 64 && callbacks.count < 255 {
            let count = min(65_536, stagedInput.count)
            let chunk = stagedInput.prefix(count); stagedInput.removeFirst(count)
            sequence += 1; pendingInput += 1
            request("terminal.input", payload: ["data": Data(chunk).base64EncodedString(), "inputSequence": sequence,
                "inputDeadline": stagedDeadline]) { [weak self] result in
                guard let self else { return }
                self.pendingInput = max(0, self.pendingInput - 1)
                if result["error"] != nil {
                    self.rejectStagedInput(result["error"] as? String ?? "Input could not be confirmed.")
                } else if self.pendingInput == 0 && self.stagedInput.isEmpty && !self.inputUncertain {
                    PeerInputRecovery.set(self.recoveryKey, uncertain: false)
                }
                self.scheduleInputFlush()
            }
        }
        scheduleInputFlush()
    }
    @objc public func acknowledgeUncertainInput() {
        reconnect()
        PeerInputRecovery.set(recoveryKey, uncertain: false)
        inputUncertain = false; sequence = 0
    }
    @objc public func reconnect() {
        connectionGeneration += 1; connection?.close(); connection = nil
        lostConnection()
        open()
    }
    @objc public func close() {
        if pendingInput > 0 || !stagedInput.isEmpty { markUncertain() }
        deliberatelyClosed = true
        ready = nil; callbacks.removeAll(); pendingInput = 0; stagedInput.removeAll(); flushScheduled = false
        healthTimer?.invalidate(); healthTimer = nil
        connectionGeneration += 1
        connection?.close(); connection = nil; connected = false
    }
    private func lostConnection() {
        connected = false; controlling = false
        if pendingInput > 0 || !stagedInput.isEmpty { markUncertain() }
        stagedInput.removeAll(keepingCapacity: false); flushScheduled = false
        let pending = callbacks; callbacks.removeAll()
        for callback in pending.values { callback(["error": "Connection lost; delivery is uncertain.", "uncertain": true]) }
        eventHandler?(["type": "disconnected", "uncertain": inputUncertain, "detail": lastConnectionError.isEmpty ? "Reconnecting to the workstation…" : lastConnectionError])
        guard !deliberatelyClosed else { return }
        reconnectAttempt += 1
        let current = connectionGeneration
        let delay = min(30.0, pow(2, Double(min(reconnectAttempt, 5))) * Double.random(in: 0.5...1))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.connectionGeneration == current else { return }
            self.open()
        }
    }
}
