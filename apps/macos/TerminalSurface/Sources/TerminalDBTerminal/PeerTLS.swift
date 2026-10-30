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
        // Forwarding replaces this application handler. Channel closure must
        // still release the original agent link and its callbacks.
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
    private var listener: Channel?
    private let admissionLock = NSLock()
    private var admitted = 0
    var accepted: ((PeerTLSLink) -> Void)?
    var listeningPort: Int { listener?.localAddress?.port ?? 0 }
    var activeConnectionCount: Int {
        admissionLock.lock(); defer { admissionLock.unlock() }; return admitted
    }

    init(identity: PeerDeviceIdentity, trust: PeerTrustStore, gate: PeerPairingGate) {
        self.identity = identity; self.trust = trust; self.gate = gate
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
            // A successful TLS CertificateVerify proves possession of the
            // pinned key. Unknown keys may enter only the pairing handler;
            // the agent separately denies every session operation until both
            // local users have approved the full device fingerprints.
            promise.succeed(.certificateVerified)
        }
    }

    func listen(port: Int, completion: @escaping (Error?) -> Void) throws {
        let context = try identity.context(server: true)
        ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 32)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .childChannelInitializer { channel in
                guard let release = self.reserveConnection() else { return channel.eventLoop.makeFailedFuture(PeerFailure("Peer connection capacity reached.")) }
                channel.closeFuture.whenComplete { _ in release() }
                let state = PeerTLSState()
                state.localPeer = PeerLAN.contains(channel.remoteAddress?.ipAddress ?? "")
                let link = PeerTLSLink(state: state)
                let tls = NIOSSLServerHandler(context: context,
                    customVerificationCallback: self.verifier(state: state, expected: nil, pairing: false))
                link.connected = { [weak self, weak link] in
                    guard let self, let link else { return }
                    self.accepted?(link)
                }
                return channel.pipeline.addHandlers(tls, link)
            }.bind(host: "::", port: port).whenComplete { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let channel): self.listener = channel; completion(nil)
                    case .failure(let error): completion(error)
                    }
                }
            }
    }

    func connect(endpoint: PeerEndpoint, expected: String?, pairing: Bool,
                 completion: @escaping (Result<PeerTLSLink, Error>) -> Void) {
        guard let release = reserveConnection() else { completion(.failure(PeerFailure("Peer connection capacity reached."))); return }
        do {
            let context = try identity.context(server: false)
            let state = PeerTLSState()
            state.localPeer = PeerLAN.contains(endpoint.host)
            let link = PeerTLSLink(state: state)
            link.pathLabel = endpoint.scope == "lan" ? "Direct LAN" : "Direct Internet"
            var completed = false
            let finish: (Result<PeerTLSLink, Error>) -> Void = { result in
                guard !completed else { return }; completed = true
                if case .failure = result { release() }
                completion(result)
            }
            link.connected = { finish(.success(link)) }
            link.disconnected = { finish(.failure(PeerFailure("The workstation rejected or closed the connection."))) }
            let tls = try NIOSSLClientHandler(context: context, serverHostname: nil,
                customVerificationCallback: verifier(state: state, expected: expected, pairing: pairing))
            let future = ClientBootstrap(group: group)
                .connectTimeout(.seconds(5))
                .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
                .channelInitializer { $0.pipeline.addHandlers(tls, link) }
                .connect(host: endpoint.host, port: endpoint.port)
            future.whenSuccess { channel in channel.closeFuture.whenComplete { _ in release() } }
            future.whenFailure { error in
                    DispatchQueue.main.async { finish(.failure(error)) }
                }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                if !completed { link.close(); finish(.failure(PeerFailure("The workstation did not complete its secure handshake."))) }
            }
        } catch { release(); completion(.failure(error)) }
    }

    // A forwarding Mac removes only its application framing. The original
    // TLS hop remains, and an additional TLS handshake runs end to end inside
    // that stream. No intermediary receives terminal plaintext or authority.
    func connectForwarded(endpoint: PeerEndpoint, gateway: String, target: String,
                          completion: @escaping (Result<PeerTLSLink, Error>) -> Void) {
        connect(endpoint: endpoint, expected: gateway, pairing: false) { result in
            guard case .success(let outer) = result, let channel = outer.channel else { completion(result); return }
            var completed = false
            let finish: (Result<PeerTLSLink, Error>) -> Void = { result in
                guard !completed else { return }; completed = true; completion(result)
            }
            outer.receive = { message in
                guard message["type"] as? String == "tunnel.ready" else {
                    outer.close(); finish(.failure(PeerFailure("The paired Mac declined forwarding."))); return
                }
                do {
                    let context = try self.identity.context(server: false)
                    let state = PeerTLSState()
                    let inner = PeerTLSLink(state: state)
                    inner.pathLabel = "Via paired Mac"
                    let tls = try NIOSSLClientHandler(context: context, serverHostname: nil,
                        customVerificationCallback: self.verifier(state: state, expected: target, pairing: false))
                    inner.connected = { finish(.success(inner)) }
                    inner.disconnected = { finish(.failure(PeerFailure("The destination could not authenticate through this Mac."))) }
                    channel.pipeline.removeHandler(outer).flatMap {
                        channel.pipeline.addHandlers(tls, inner)
                    }.whenFailure { error in DispatchQueue.main.async { finish(.failure(error)) } }
                } catch { outer.close(); finish(.failure(error)) }
            }
            outer.send(["type": "tunnel.open", "target": target])
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                if !completed { outer.close(); finish(.failure(PeerFailure("The forwarding connection timed out."))) }
            }
        }
    }

    func forward(_ source: PeerTLSLink, endpoints: [PeerEndpoint]) {
        guard let channel = source.channel else { return }
        guard let release = reserveConnection() else { source.close(); return }
        channel.closeFuture.whenComplete { _ in release() }
        func attempt(_ remaining: ArraySlice<PeerEndpoint>) {
            guard channel.isActive else { return }
            guard let endpoint = remaining.first else {
                source.send(["type": "error", "detail": "The destination is unreachable from this Mac."]); source.close(); return
            }
            ClientBootstrap(group: group).connectTimeout(.seconds(4))
                .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
                .channelOption(ChannelOptions.autoRead, value: false)
                .connect(host: endpoint.host, port: endpoint.port).whenComplete { result in
                    switch result {
                    case .failure: DispatchQueue.main.async { attempt(remaining.dropFirst()) }
                    case .success(let destination):
                        guard channel.isActive else { destination.close(promise: nil); return }
                        let outbound = PeerTunnelPipe(other: channel)
                        let inbound = PeerTunnelPipe(other: destination)
                        destination.pipeline.addHandler(outbound).flatMap {
                            channel.eventLoop.submit {
                                // Queue the framed acknowledgement before replacing
                                // the framing handler; the client waits for it.
                                var buffer = channel.allocator.buffer(capacity: 64)
                                buffer.writeBytes(try PeerProtocol.encode(["type": "tunnel.ready"]))
                                channel.writeAndFlush(buffer, promise: nil)
                            }
                        }.flatMap {
                            channel.pipeline.removeHandler(source)
                        }.flatMap {
                            channel.pipeline.addHandler(inbound)
                        }.flatMap {
                            destination.setOption(ChannelOptions.autoRead, value: true)
                        }.whenFailure { _ in
                            channel.close(promise: nil); destination.close(promise: nil)
                        }
                    }
                }
        }
        attempt(endpoints[...])
    }
}

private final class PeerTunnelPipe: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let other: Channel
    private var queued = 0
    init(other: Channel) { self.other = other }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        queued += buffer.readableBytes
        guard queued <= PeerProtocol.maximumQueuedBytes else {
            context.close(promise: nil); other.close(promise: nil); return
        }
        let source = context.channel
        if !other.isWritable { source.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in source.close(promise: nil) } }
        other.writeAndFlush(buffer).whenComplete { result in
            source.eventLoop.execute {
                self.queued -= buffer.readableBytes
                if case .failure = result { source.close(promise: nil) }
            }
        }
    }
    func channelWritabilityChanged(context: ChannelHandlerContext) {
        other.setOption(ChannelOptions.autoRead, value: context.channel.isWritable).whenFailure { _ in self.other.close(promise: nil) }
        context.fireChannelWritabilityChanged()
    }
    func channelInactive(context: ChannelHandlerContext) { other.close(promise: nil); context.fireChannelInactive() }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil); other.close(promise: nil) }
}
