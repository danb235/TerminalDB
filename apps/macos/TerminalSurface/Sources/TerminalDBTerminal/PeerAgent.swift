import Foundation
import Network
import AppKit

private final class PendingPeerPair {
    let link: PeerTLSLink
    var name = "Nearby Mac"
    var endpoint: PeerEndpoint?
    var localApproval = false
    var remoteApproval = false
    var infoReady = false
    let initiatedHere: Bool
    init(_ link: PeerTLSLink, endpoint: PeerEndpoint?, initiatedHere: Bool) {
        self.link = link; self.endpoint = endpoint; self.initiatedHere = initiatedHere
    }
}

@objc(TDBPeerAgent)
public final class TDBPeerAgent: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private var identity: PeerDeviceIdentity!
    private var trust: PeerTrustStore!
    private let gate = PeerPairingGate()
    private var network: PeerTLSNetwork!
    private var listener: PeerLocalListener?
    private var advertisement: NetService?
    private let browser = NetServiceBrowser()
    private var services: [String: NetService] = [:]
    private var serviceTXT: [String: Data] = [:]
    private var nearby: [String: PeerEndpoint] = [:]
    private var pendingPairs: [String: PendingPeerPair] = [:]
    private var links: [String: PeerTLSLink] = [:]
    private var localClients: [String: PeerLocalConnection] = [:]
    private var hostLinks: [String: PeerLocalConnection] = [:]
    private var wakeObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var networkObserver: NSObjectProtocol?
    private var networkGeneration = 0
    private var sleeping = false
    private var applyingRevocations = false
    private var status = "Starting"
    private var statusDetail = ""

    @objc public func start() throws {
        do { identity = try PeerDeviceIdentity() }
        catch {
            let detail = (error as? PeerFailure)?.message ?? "macOS could not initialize the device identity. Check Keychain access, then reopen TerminalDB."
            try? PeerPaths.save(Data(detail.utf8), name: "startup-error.txt")
            throw PeerFailure(detail)
        }
        try? FileManager.default.removeItem(at: PeerPaths.file("startup-error.txt"))
        trust = try PeerTrustStore()
        network = PeerTLSNetwork(identity: identity, trust: trust, gate: gate)
        network.accepted = { [weak self] link in self?.acceptNetwork(link) }
        listener = try PeerLocalListener(name: "peer")
        listener?.accepted = { [weak self] connection, hello in self?.acceptLocal(connection, hello: hello) }
        try network.listen(port: trust.settings.listenPort) { [weak self] error in
            guard let self else { return }
            self.status = error == nil ? "Ready" : "Unavailable"
            self.statusDetail = error == nil ? "Paired Macs connect directly over your LAN or VPN. No internet ports or cloud service are needed." : "The peer listener could not start. Check the configured port and macOS network permissions."
            if error == nil { self.advertise() }
            self.broadcastState()
        }
        browser.delegate = self
        browser.searchForServices(ofType: PeerProtocol.serviceType, inDomain: "local.")
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.sleeping = true; self.gate.close(); self.expirePairing()
            self.disconnectNetworkViews()
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.sleeping = false; self.scheduleNetworkRefresh()
        }
        _ = PrivateNetworkChanges.shared
        networkObserver = NotificationCenter.default.addObserver(forName: PrivateNetworkChanges.notification, object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.sleeping else { return }
            self.scheduleNetworkRefresh()
        }
    }
    deinit {
        if let networkObserver { NotificationCenter.default.removeObserver(networkObserver) }
        for observer in [wakeObserver, sleepObserver].compactMap({ $0 }) {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    private func disconnectNetworkViews() {
        for link in Array(links.values) { link.close() }
    }
    private func scheduleNetworkRefresh() {
        networkGeneration += 1
        let generation = networkGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.sleeping, generation == self.networkGeneration else { return }
            self.gate.close(); self.expirePairing()
            self.disconnectNetworkViews()
            self.browser.stop()
            for service in self.services.values { service.stopMonitoring(); service.stop() }
            self.services.removeAll(); self.serviceTXT.removeAll(); self.nearby.removeAll()
            self.network.refreshListeners { [weak self] error in
                guard let self else { return }
                self.status = error == nil ? "Ready" : "Unavailable"
                self.statusDetail = error == nil
                    ? "Direct connections over your LAN or VPN. Sleeping workstations must be woken before reconnecting."
                    : "Connect your LAN or VPN, then check Local Network permission and the workstation’s internal address."
                if error == nil { self.advertise() }
                self.broadcastState()
            }
            self.browser.searchForServices(ofType: PeerProtocol.serviceType, inDomain: "local.")
        }
    }

    private func advertise() {
        advertisement?.stop()
        let service = NetService(domain: "local.", type: PeerProtocol.serviceType,
                                 name: "tdb-" + identity.fingerprint.prefix(12), port: Int32(trust.settings.listenPort))
        service.setTXTRecord(discoveryTXT())
        service.delegate = self
        service.publish()
        advertisement = service
    }

    private func discoveryTXT() -> Data {
        var record = ["v": Data("1".utf8)]
        if gate.isOpen {
            let name = PeerProtocol.displayName(Host.current().localizedName ?? "Mac")
            // A DNS-SD TXT entry is limited to 255 bytes, including its key.
            let short = String(String.UnicodeScalarView(name.unicodeScalars.prefix(40)))
            record["name"] = Data(short.utf8); record["pairing"] = Data("1".utf8)
        }
        return NetService.data(fromTXTRecord: record)
    }

    private func acceptLocal(_ connection: PeerLocalConnection, hello: [String: Any]) {
        localClients[connection.id] = connection
        let originalClose = connection.disconnected
        var remote: PeerTLSLink?
        var closed = false
        connection.receive = { [weak self, weak connection] message in
            guard let self, let connection else { return }
            if message["type"] as? String == "connect", let peerID = message["peerId"] as? String {
                guard self.trust.contains(peerID) else {
                    connection.send(["type": "error", "detail": "This Mac is no longer paired with that Mac. Open Workstations → Add Mac on both Macs to pair again."])
                    connection.close(); return
                }
                self.connect(peerID: peerID, cancelled: { closed }) { result in
                    guard !closed else { if case .success(let link) = result { link.close() }; return }
                    switch result {
                    case .failure:
                        connection.send(["type": "error", "detail": "The paired Mac is unreachable. Connect your LAN or VPN, then check its internal address, power, and Local Network permission."])
                        connection.close()
                    case .success(let link):
                        remote = link
                        link.receive = { message in
                            var message = message
                            if message["type"] as? String == "ready" {
                                message["connectionPath"] = link.pathLabel
                            }
                            connection.send(message)
                        }
                        link.disconnected = { [weak self] in self?.links.removeValue(forKey: link.id); connection.close() }
                        link.send(["type": "hello", "version": PeerProtocol.version,
                                   "clientId": hello["clientId"] as? String ?? UUID().uuidString])
                    }
                }
            } else if let remote { remote.send(message) }
            else { self.manage(message, connection: connection) }
        }
        connection.disconnected = { [weak self, weak connection] in
            closed = true
            originalClose?(); remote?.close()
            if let connection { self?.localClients.removeValue(forKey: connection.id) }
        }
        connection.send(["type": "ready", "version": PeerProtocol.version])
    }

    private func manage(_ message: [String: Any], connection: PeerLocalConnection) {
        guard let operation = message["operation"] as? String,
              let request = message["requestId"] as? String, UUID(uuidString: request) != nil else { connection.close(); return }
        func reply(_ payload: [String: Any] = [:]) {
            var result = payload; result["type"] = "reply"; result["requestId"] = request
            connection.send(result)
        }
        do {
            switch operation {
            case "peers.state": reply(state())
            case "peers.pairing.open":
                gate.open(); advertise(); reply(state()); broadcastState()
                DispatchQueue.main.asyncAfter(deadline: .now() + 180) { [weak self] in self?.expirePairing() }
            case "peers.pairing.close": gate.close(); expirePairing(); reply(state())
            case "peers.pair":
                guard gate.isOpen, let service = message["service"] as? String, let endpoint = nearby[service] else {
                    throw PeerFailure("Open pairing on both Macs, then select a discovered Mac on this LAN.")
                }
                network.connect(endpoint: endpoint, expected: nil, pairing: true) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .failure: reply(["error": "The nearby Mac could not pair. Open pairing on both Macs, allow Local Network access, and allow TerminalDB incoming connections in macOS Firewall settings."])
                    case .success(let link):
                        self.track(link)
                        let pending = self.stagePairing(link, endpoint: endpoint, initiatedHere: true)
                        var result = self.state(); result["requestedCandidate"] = pending.link.id; reply(result)
                    }
                }
            case "peers.approve":
                guard let id = message["candidate"] as? String, let candidate = pendingPairs[id], gate.isOpen, candidate.infoReady,
                      message["fingerprint"] as? String == candidate.link.peerID else {
                    throw PeerFailure("This pairing expired or its fingerprint changed. Start pairing again.")
                }
                candidate.localApproval = true
                candidate.link.send(["type": "pair.approve"])
                try finishPairing(candidate)
                reply(state()); broadcastState()
            case "peers.remove":
                let id = message["peerId"] as? String ?? ""
                guard trust.contains(id) else { throw PeerFailure("That workstation is no longer paired.") }
                try trust.update { settings in
                    if message["otherMacs"] as? Bool == true {
                        var pending = settings.pendingRevocations ?? [:]
                        for host in settings.peers.keys where host != id {
                            pending[host] = Array(Set((pending[host] ?? []) + [id])).sorted()
                        }
                        settings.pendingRevocations = pending
                    }
                    settings.peers.removeValue(forKey: id)
                    settings.pendingRevocations?.removeValue(forKey: id)
                }
                disconnectPeer(id)
                reply(state()); broadcastState(); applyPendingRevocations()
            case "peers.retryRemovals": applyPendingRevocations(); reply(state())
            case "peers.endpoint":
                let id = message["peerId"] as? String ?? ""
                let text = (message["address"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let endpoints = text.isEmpty ? [] : [try PeerEndpoint.parse(text)]
                try trust.update {
                    guard var peer = $0.peers[id] else { throw PeerFailure("Pair this workstation before saving its address.") }
                    peer.endpoints.removeAll { $0.scope == "manual" }
                    peer.endpoints.append(contentsOf: endpoints); $0.peers[id] = peer
                }
                reply(state()); broadcastState()
            case "peers.testAddress":
                guard let id = message["peerId"] as? String, let peer = trust.settings.peers[id],
                      let endpoint = peer.endpoints.first(where: { $0.scope == "manual" }) ?? peer.endpoints.first else {
                    throw PeerFailure("Select a paired workstation and save its internal LAN or VPN address first.")
                }
                network.connect(endpoint: endpoint, expected: id, pairing: false) { result in
                    if case .success(let link) = result {
                        link.close(); reply(["testResult": "This Mac reached the workstation’s internal address and verified its paired device key."])
                    } else {
                        reply(["error": "The workstation is unreachable. Connect your VPN or LAN, then check its internal address, power and Local Network permission."])
                    }
                }
            default: reply(["error": "This peer management operation is unsupported."])
            }
        } catch { reply(["error": error.localizedDescription]) }
    }

    private func acceptNetwork(_ link: PeerTLSLink) {
        track(link)
        if !trust.contains(link.peerID) {
            guard gate.isOpen else { link.close(); return }
            let endpoint = link.channel?.remoteAddress?.ipAddress.map {
                PeerEndpoint(host: $0, port: PeerProtocol.defaultPort, scope: "lan")
            }
            _ = stagePairing(link, endpoint: endpoint, initiatedHere: false)
            return
        }
        var applicationAccepted = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak link] in
            guard let link, !applicationAccepted else { return }
            link.close()
        }
        let originalClose = link.disconnected
        link.disconnected = { [weak self] in
            originalClose?()
            self?.links.removeValue(forKey: link.id)
            self?.hostLinks.removeValue(forKey: link.id)?.close()
        }
        link.receive = { [weak self, weak link] message in
            guard let self, let link else { return }
            guard self.trust.contains(link.peerID) else { link.close(); return }
            if let host = self.hostLinks[link.id] { host.send(message); return }
            if message["type"] as? String == "revocation.apply" {
                applicationAccepted = true
                guard let target = message["target"] as? String, target.count == 64,
                      target.allSatisfy({ $0.isHexDigit }), target != self.identity.fingerprint else { link.close(); return }
                do {
                    try self.trust.update { $0.peers.removeValue(forKey: target) }
                    self.disconnectPeer(target)
                    link.send(["type": "revocation.result", "accepted": true]); self.broadcastState()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { link.close() }
                } catch { link.close() }
                return
            }
            guard message["type"] as? String == "hello", message["version"] as? Int == PeerProtocol.version,
                  let client = message["clientId"] as? String, UUID(uuidString: client) != nil else { link.close(); return }
            applicationAccepted = true
            do {
                let host = try PeerLocalConnection.connect("host")
                self.hostLinks[link.id] = host
                host.receive = { response in
                    var response = response
                    if response["type"] as? String == "ready" {
                        response["peerConnected"] = true
                    }
                    link.send(response)
                }
                host.disconnected = { link.close() }
                host.start()
                host.send(["type": "hello", "version": PeerProtocol.version, "role": "peer",
                           "peerId": link.peerID, "clientId": client,
                           "secret": try String(contentsOf: PeerPaths.file("host.secret"), encoding: .utf8)])
            } catch {
                link.send(["type": "error", "detail": "The Mac's session service is unavailable."]); link.close()
            }
        }
    }

    private func stagePairing(_ link: PeerTLSLink, endpoint: PeerEndpoint?, initiatedHere: Bool) -> PendingPeerPair {
        // Simultaneous clicks must converge on the same TLS connection. Either
        // Mac may initiate alone; only a duplicate uses this ordering rule.
        let preferLocalInitiator = identity.fingerprint < link.peerID
        if let existing = pendingPairs.values.first(where: { $0.link.peerID == link.peerID }) {
            if existing.initiatedHere == preferLocalInitiator || initiatedHere != preferLocalInitiator {
                link.close(); return existing
            }
            pendingPairs.removeValue(forKey: existing.link.id); existing.link.close()
        }
        let candidate = PendingPeerPair(link, endpoint: endpoint, initiatedHere: initiatedHere)
        pendingPairs[link.id] = candidate
        installPairing(candidate); sendPairInfo(link); broadcastState()
        return candidate
    }

    private func installPairing(_ candidate: PendingPeerPair) {
        let link = candidate.link
        link.receive = { [weak self, weak candidate] message in
            guard let self, let candidate, self.gate.isOpen else { link.close(); return }
            switch message["type"] as? String {
            case "pair.info":
                let name = message["name"] as? String ?? "Mac"
                candidate.name = PeerProtocol.displayName(name)
                candidate.infoReady = true
                if let port = message["port"] as? Int, (1...65535).contains(port) { candidate.endpoint?.port = port }
                self.broadcastState()
            case "pair.approve":
                candidate.remoteApproval = true
                do { try self.finishPairing(candidate) } catch { link.close() }
                self.broadcastState()
            default: link.close()
            }
        }
        link.disconnected = { [weak self] in
            self?.pendingPairs.removeValue(forKey: link.id)
            self?.links.removeValue(forKey: link.id)
            self?.broadcastState()
        }
    }

    private func sendPairInfo(_ link: PeerTLSLink) {
        link.send(["type": "pair.info", "name": Host.current().localizedName ?? "Mac", "port": trust.settings.listenPort])
    }
    private func finishPairing(_ candidate: PendingPeerPair) throws {
        guard candidate.localApproval && candidate.remoteApproval else { return }
        let id = candidate.link.peerID
        guard id != identity.fingerprint else { throw PeerFailure("A workstation cannot pair with itself.") }
        try trust.update { settings in
            settings.peers[id] = TrustedPeer(id: id, name: candidate.name,
                endpoints: candidate.endpoint.map { [$0] } ?? [], pairedAt: Date())
        }
        pendingPairs.removeValue(forKey: candidate.link.id)
        // Reconnect through ordinary pinned TLS after pairing. The pairing
        // channel itself never becomes an execution channel.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { candidate.link.close() }
    }
    private func expirePairing() {
        guard !gate.isOpen else { return }
        // Republish the minimal record so names from the pairing window are
        // withdrawn along with readiness. Established TLS sessions stay open.
        advertise()
        for pair in pendingPairs.values { pair.link.close() }
        pendingPairs.removeAll(); broadcastState()
    }

    private func connect(peerID: String, cancelled: @escaping () -> Bool = { false }, completion: @escaping (Result<PeerTLSLink, Error>) -> Void) {
        guard let peer = trust.settings.peers[peerID] else {
            completion(.failure(PeerFailure("This workstation is not paired."))); return
        }
        func priority(_ endpoint: PeerEndpoint) -> Int {
            if endpoint.scope == "lan" && PeerLAN.contains(endpoint.host) { return 0 }
            return endpoint.scope == "manual" ? 1 : 2
        }
        let endpoints = peer.endpoints.sorted { priority($0) < priority($1) }
        func attempt(_ remaining: ArraySlice<PeerEndpoint>) {
            guard !cancelled() else { completion(.failure(PeerFailure("Connection cancelled."))); return }
            guard let endpoint = remaining.first else {
                completion(.failure(PeerFailure("The workstation is unreachable. Connect your LAN or VPN and check its saved internal address."))); return
            }
            network.connect(endpoint: endpoint, expected: peerID, pairing: false) { result in
                switch result {
                case .success(let link):
                    if cancelled() { link.close(); completion(.failure(PeerFailure("Connection cancelled."))); return }
                    self.track(link); completion(.success(link))
                case .failure: attempt(remaining.dropFirst())
                }
            }
        }
        attempt(endpoints[...])
    }

    private func track(_ link: PeerTLSLink) {
        links[link.id] = link
        link.channel?.closeFuture.whenComplete { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.links.removeValue(forKey: link.id)
                self.hostLinks.removeValue(forKey: link.id)?.close()
                self.pendingPairs.removeValue(forKey: link.id)
            }
        }
    }
    private func disconnectPeer(_ id: String) {
        for link in Array(links.values) where link.peerID == id { link.close() }
    }

    private func applyPendingRevocations() {
        guard !applyingRevocations else { return }
        applyingRevocations = true
        let work = (trust.settings.pendingRevocations ?? [:]).flatMap { host, targets in targets.map { (host, $0) } }
        func next(_ items: ArraySlice<(String, String)>) {
            guard let item = items.first else { self.applyingRevocations = false; self.broadcastState(); return }
            self.connect(peerID: item.0) { result in
                guard case .success(let link) = result else { next(items.dropFirst()); return }
                var finished = false
                let finish: (Bool) -> Void = { accepted in
                    guard !finished else { return }; finished = true
                    if accepted {
                        try? self.trust.update {
                            $0.pendingRevocations?[item.0]?.removeAll { $0 == item.1 }
                            if $0.pendingRevocations?[item.0]?.isEmpty == true { $0.pendingRevocations?.removeValue(forKey: item.0) }
                        }
                    }
                    self.links.removeValue(forKey: link.id); link.close(); next(items.dropFirst())
                }
                link.receive = { message in
                    if message["type"] as? String == "revocation.result" { finish(message["accepted"] as? Bool == true) }
                }
                link.disconnected = { finish(false) }
                link.send(["type": "revocation.apply", "target": item.1])
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) { finish(false) }
            }
        }
        next(work[...])
    }

    private func state() -> [String: Any] {
        let peers: [[String: Any]] = trust.settings.peers.values.sorted { $0.name < $1.name }.map {
            ["id": $0.id, "name": $0.name, "endpoints": $0.endpoints.map { ["address": $0.display, "scope": $0.scope] }]
        }
        return ["status": status, "detail": statusDetail, "fingerprint": identity.fingerprint,
                "hardwareBacked": identity.hardwareBacked, "pairingOpen": gate.isOpen, "port": trust.settings.listenPort,
                "peers": peers,
                "pendingRemovals": (trust.settings.pendingRevocations ?? [:]).keys.sorted().map { trust.settings.peers[$0]?.name ?? "Unavailable Mac" },
                "nearby": nearby.keys.sorted().map { service -> [String: Any] in
                    let data = serviceTXT[service] ?? services[service]?.txtRecordData() ?? Data()
                    let txt = NetService.dictionary(fromTXTRecord: data)
                    let name = txt["name"].flatMap { String(data: $0, encoding: .utf8) }
                    return ["service": service, "address": nearby[service]!.display,
                            "name": name.map(PeerProtocol.displayName) ?? "Nearby Mac",
                            "pairingReady": txt["pairing"] == Data("1".utf8)]
                },
                "candidates": pendingPairs.values.map { ["id": $0.link.id, "name": $0.name,
                    "fingerprint": $0.link.peerID, "ready": $0.infoReady,
                    "approvedHere": $0.localApproval, "approvedThere": $0.remoteApproval] }]
    }
    private func broadcastState() {
        var result = state(); result["type"] = "peers.state"
        for connection in localClients.values { connection.send(result) }
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        statusDetail = "Nearby discovery is unavailable. Allow TerminalDB in System Settings → Privacy & Security → Local Network, then reopen it. Saved paired addresses can still connect."
        broadcastState()
    }
    public func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        statusDetail = "Nearby advertising is unavailable. Check Local Network permission and whether another TerminalDB peer service is using this device identity."
        broadcastState()
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard service.name != advertisement?.name, services.count < 128 else { return }
        services[service.name]?.stopMonitoring()
        services[service.name] = service
        service.delegate = self; service.resolve(withTimeout: 5)
    }
    public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services[service.name]?.stopMonitoring()
        services.removeValue(forKey: service.name); serviceTXT.removeValue(forKey: service.name)
        nearby.removeValue(forKey: service.name); broadcastState()
    }
    public func netService(_ sender: NetService, didUpdateTXTRecord data: Data) {
        guard services[sender.name] === sender, data.count <= 4096 else { return }
        serviceTXT[sender.name] = data; broadcastState()
    }
    public func netServiceDidResolveAddress(_ sender: NetService) {
        guard services[sender.name] === sender else { return }
        sender.startMonitoring()
        guard (1...65535).contains(sender.port) else { return }
        let addresses = (sender.addresses ?? []).sorted { a, b in
            a.withUnsafeBytes { $0.load(as: sockaddr.self).sa_family } == AF_INET &&
            b.withUnsafeBytes { $0.load(as: sockaddr.self).sa_family } != AF_INET
        }
        var resolved: String?
        for data in addresses {
            var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = data.withUnsafeBytes { raw -> Int32 in
                guard let base = raw.baseAddress else { return -1 }
                return getnameinfo(base.assumingMemoryBound(to: sockaddr.self), socklen_t(data.count), &name,
                                   socklen_t(name.count), nil, 0, NI_NUMERICHOST)
            }
            if result == 0, PrivateNetwork.allows(String(cString: name)) { resolved = String(cString: name); break }
        }
        guard let host = resolved else { return }
        let endpoint = PeerEndpoint(host: host, port: sender.port, scope: "lan")
        nearby[sender.name] = endpoint
        let generation = networkGeneration
        // Service names are address hints only. Only refresh a saved address
        // after a pinned-key handshake, never by matching this public prefix.
        for peer in trust.settings.peers.values where sender.name == "tdb-" + peer.id.prefix(12) {
            network.connect(endpoint: endpoint, expected: peer.id, pairing: false) { [weak self] result in
                guard let self, case .success(let link) = result else { return }
                link.close()
                guard generation == self.networkGeneration else { return }
                try? self.trust.update {
                    $0.peers[peer.id]?.endpoints.removeAll { $0.scope == "lan" }
                    $0.peers[peer.id]?.endpoints.insert(endpoint, at: 0)
                }
                self.broadcastState()
            }
        }
        broadcastState()
    }
}
