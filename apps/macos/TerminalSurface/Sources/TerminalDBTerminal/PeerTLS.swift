import Foundation
import NIO
import NIOSSL
import NIOTLS

final class PeerPairingGate {
    private let lock = NSLock()
    private var deadline: TimeInterval = 0
    func open() { lock.lock(); deadline = PeerClock.now + 180; lock.unlock() }
    func close() { lock.lock(); deadline = 0; lock.unlock() }
    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return PeerClock.now < deadline }
}

final class PeerTLSState: @unchecked Sendable {
    // Set by verification on the connection event loop, then read on that
    // same loop before dispatching an authenticated event to the main queue.
    var peerID = ""
    var localPeer = false
}

final class PeerTLSLink: ChannelInboundHandler, RemovableChannelHandler, PeerConnection, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let id = UUID().uuidString
    let tlsState: PeerTLSState
    var pathLabel = "Direct LAN"
    var channel: Channel?
    var receive: (([String: Any]) -> Void)?
    var connected: (() -> Void)?
    var disconnected: (() -> Void)?
    private var decoder = PeerFrameDecoder()
    private var handshake = false
    var handshakeComplete: Bool { handshake }
    private var closeDelivered = false
    private var queuedBytes = 0
    private let sendBudget = PeerQueueBudget()
    private let deliveryBudget = PeerQueueBudget()
    private var receiveBudget = 0
    private var budgetStarted = PeerClock.now

    init(state: PeerTLSState) { tlsState = state }
    var peerID: String { tlsState.peerID }

    func handlerAdded(context: ChannelHandlerContext) {
        channel = context.channel
        // Channel closure releases the agent link and callbacks exactly once.
        context.channel.closeFuture.whenComplete { _ in self.deliverClose() }
    }
    private func deliverClose() {
        DispatchQueue.main.async {
            guard !self.closeDelivered else { return }; self.closeDelivered = true
            let callback = self.disconnected
            self.disconnected = nil; self.receive = nil; self.connected = nil
            callback?()
        }
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted = event {
            guard tlsState.peerID.count == 64 else { context.close(promise: nil); return }
            handshake = true
            DispatchQueue.main.async { self.connected?() }
        }
        context.fireUserInboundEventTriggered(event)
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard handshake else { context.close(promise: nil); return }
        let buffer = unwrapInboundIn(data)
        let now = PeerClock.now
        if now - budgetStarted >= 1 { budgetStarted = now; receiveBudget = 0 }
        receiveBudget += buffer.readableBytes
        guard receiveBudget <= 32 * PeerProtocol.maximumFrame else { context.close(promise: nil); return }
        do {
            let messages = try decoder.accept(Data(buffer.readableBytesView))
            let cost = max(buffer.readableBytes, decoder.deliveryBytes)
            guard deliveryBudget.reserve(cost) else { context.close(promise: nil); return }
            DispatchQueue.main.async {
                defer { self.deliveryBudget.release(cost) }
                for message in messages { self.receive?(message) }
            }
        } catch { context.close(promise: nil) }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
    func channelInactive(context: ChannelHandlerContext) {
        deliverClose()
        context.fireChannelInactive()
    }
    func send(_ message: [String: Any]) {
        guard let channel, let frame = try? PeerProtocol.encode(message) else { close(); return }
        guard sendBudget.reserve(frame.count) else { close(); return }
        channel.eventLoop.execute {
            defer { self.sendBudget.release(frame.count) }
            guard channel.isActive, self.queuedBytes + frame.count <= PeerProtocol.maximumQueuedBytes else {
                channel.close(promise: nil); return
            }
            self.queuedBytes += frame.count
            var buffer = channel.allocator.buffer(capacity: frame.count)
            buffer.writeBytes(frame)
            channel.writeAndFlush(buffer).whenComplete { _ in self.queuedBytes -= frame.count }
        }
    }
    func close() { channel?.close(promise: nil) }
}

final class PeerTLSNetwork {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    private let identity: PeerDeviceIdentity
    private let trust: PeerTrustStore
    private let gate: PeerPairingGate
    private var listeners: [String: Channel] = [:]
    private var port = 0
    private var listenerGeneration = 0
    private let resolver = OperationQueue()
    private let admissionLock = NSLock()
    private var admitted = 0
    var accepted: ((PeerTLSLink) -> Void)?
    var listeningPort: Int { port }
    var activeConnectionCount: Int {
        admissionLock.lock(); defer { admissionLock.unlock() }; return admitted
    }

    init(identity: PeerDeviceIdentity, trust: PeerTrustStore, gate: PeerPairingGate) {
        self.identity = identity; self.trust = trust; self.gate = gate
        resolver.maxConcurrentOperationCount = 4
    }

    private func reserveConnection() -> (() -> Void)? {
        admissionLock.lock()
        guard admitted < PeerProtocol.maximumConnections else { admissionLock.unlock(); return nil }
        admitted += 1; admissionLock.unlock()
        var released = false
        return {
            self.admissionLock.lock(); defer { self.admissionLock.unlock() }
            if !released { released = true; self.admitted -= 1 }
        }
    }

    fileprivate func verifier(state: PeerTLSState, expected: String?, pairing: Bool) -> NIOSSLCustomVerificationCallback {
        { [trust, gate] certificates, promise in
            guard certificates.count == 1, let leaf = certificates.first,
                  let fingerprint = try? PeerDeviceIdentity.fingerprint(leaf),
                  expected == nil || expected == fingerprint,
                  trust.contains(fingerprint) || (state.localPeer && (pairing || gate.isOpen)) else {
                promise.succeed(.failed); return
            }
            state.peerID = fingerprint
            promise.succeed(.certificateVerified)
        }
    }

    func listen(port: Int, completion: @escaping (Error?) -> Void) throws {
        self.port = port
        refreshListeners(completion: completion)
    }

    func refreshListeners(completion: @escaping (Error?) -> Void) {
        listenerGeneration += 1
        let generation = listenerGeneration
        let hosts = PrivateNetwork.interfaceAddresses()
        for host in Array(listeners.keys) where !hosts.contains(host) {
            listeners.removeValue(forKey: host)?.close(promise: nil)
        }
        do {
            let context = try identity.context(server: true)
            func bind(_ remaining: ArraySlice<String>, error: Error? = nil) {
                guard generation == self.listenerGeneration else { return }
                guard let host = remaining.first else {
                    completion(self.listeners.isEmpty ? (error ?? PeerFailure("No internal network interface is available.")) : nil)
                    return
                }
                if self.listeners[host] != nil { bind(remaining.dropFirst(), error: error); return }
                ServerBootstrap(group: self.group)
                    .serverChannelOption(ChannelOptions.backlog, value: 32)
                    .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                    .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
                    .childChannelInitializer { channel in
                        guard PrivateNetwork.allows(channel.remoteAddress?.ipAddress ?? ""),
                              let release = self.reserveConnection() else {
                            return channel.eventLoop.makeFailedFuture(PeerFailure("This connection is not permitted on the private network."))
                        }
                        channel.closeFuture.whenComplete { _ in release() }
                        let state = PeerTLSState()
                        state.localPeer = PeerLAN.contains(channel.remoteAddress?.ipAddress ?? "")
                        let link = PeerTLSLink(state: state)
                        let deadline = channel.eventLoop.scheduleTask(in: .seconds(10)) { [weak link] in
                            if link?.handshakeComplete != true { channel.close(promise: nil) }
                        }
                        channel.closeFuture.whenComplete { _ in deadline.cancel() }
                        let tls = NIOSSLServerHandler(context: context,
                            customVerificationCallback: self.verifier(state: state, expected: nil, pairing: false))
                        link.connected = { [weak self, weak link] in
                            guard let self, let link else { return }
                            self.accepted?(link)
                        }
                        return channel.pipeline.addHandlers(tls, link)
                    }.bind(host: host, port: self.port).whenComplete { result in
                        DispatchQueue.main.async {
                            guard generation == self.listenerGeneration else {
                                if case .success(let channel) = result { channel.close(promise: nil) }
                                return
                            }
                            switch result {
                            case .success(let channel):
                                self.listeners[host] = channel
                                self.port = channel.localAddress?.port ?? self.port
                                bind(remaining.dropFirst(), error: error)
                            case .failure(let failure): bind(remaining.dropFirst(), error: failure)
                            }
                        }
                    }
            }
            bind(hosts[...])
        } catch { completion(error) }
    }

    func connect(endpoint: PeerEndpoint, expected: String?, pairing: Bool,
                 completion: @escaping (Result<PeerTLSLink, Error>) -> Void) {
        guard let release = reserveConnection() else { completion(.failure(PeerFailure("Workstation connection capacity reached."))); return }
        var completed = false, resolving = true
        var current: PeerTLSLink?
        let finish: (Result<PeerTLSLink, Error>) -> Void = { result in
            guard !completed else { return }; completed = true
            if case .success(let link) = result {
                link.channel?.closeFuture.whenComplete { _ in release() }
            } else if !resolving { release() }
            completion(result)
        }
        // Keep the admission slot until an outstanding lookup returns, even if
        // its caller has timed out. Slow DNS cannot create an unbounded queue.
        resolver.addOperation {
            let result = Result { try PrivateNetwork.resolve(endpoint) }
            DispatchQueue.main.async {
                resolving = false
                guard !completed else { release(); return }
                do {
                    let addresses = try result.get()
                    let context = try self.identity.context(server: false)
                    func attempt(_ remaining: ArraySlice<SocketAddress>) {
                        guard !completed else { return }
                        guard let address = remaining.first else {
                            finish(.failure(PeerFailure("The workstation is unreachable. Connect your VPN or check its internal address and power."))); return
                        }
                        let state = PeerTLSState()
                        state.localPeer = PeerLAN.contains(address.ipAddress ?? "")
                        let link = PeerTLSLink(state: state)
                        link.pathLabel = state.localPeer ? "Direct LAN" : "LAN / VPN"
                        current = link
                        var attemptFinished = false
                        let failed: () -> Void = {
                            guard !attemptFinished, !completed else { return }; attemptFinished = true
                            link.close(); attempt(remaining.dropFirst())
                        }
                        link.connected = { [weak link] in
                            guard let link, !attemptFinished, !completed else { return }
                            attemptFinished = true; finish(.success(link))
                        }
                        link.disconnected = failed
                        do {
                            let tls = try NIOSSLClientHandler(context: context, serverHostname: nil,
                                customVerificationCallback: self.verifier(state: state, expected: expected, pairing: pairing))
                            ClientBootstrap(group: self.group)
                                .connectTimeout(.seconds(3))
                                .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
                                .channelInitializer { $0.pipeline.addHandlers(tls, link) }
                                .connect(to: address).whenFailure { _ in DispatchQueue.main.async { failed() } }
                        } catch { failed() }
                    }
                    attempt(addresses.prefix(8))
                } catch { finish(.failure(error)) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            if !completed { current?.close(); finish(.failure(PeerFailure("The workstation did not complete its secure connection. Check the VPN and internal address."))) }
        }
    }
}
