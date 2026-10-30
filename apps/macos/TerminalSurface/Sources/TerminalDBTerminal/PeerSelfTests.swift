import Foundation
import Security
import NIO

@objc(TDBPeerSelfTests)
public final class TDBPeerSelfTests: NSObject {
    @objc public static func run() -> Bool {
        var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool) throws {
            guard try condition() else { throw PeerFailure("A native peer regression check failed.") }
            checks += 1
        }
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("terminaldb-peer-tests-" + UUID().uuidString)
        let oldDirectory = ProcessInfo.processInfo.environment["TERMINALDB_PEER_STATE_DIR"]
        let oldIdentity = ProcessInfo.processInfo.environment["TERMINALDB_PEER_EPHEMERAL_IDENTITY"]
        setenv("TERMINALDB_PEER_STATE_DIR", directory.path, 1)
        setenv("TERMINALDB_PEER_EPHEMERAL_IDENTITY", "1", 1)
        defer {
            if let oldDirectory { setenv("TERMINALDB_PEER_STATE_DIR", oldDirectory, 1) } else { unsetenv("TERMINALDB_PEER_STATE_DIR") }
            if let oldIdentity { setenv("TERMINALDB_PEER_EPHEMERAL_IDENTITY", oldIdentity, 1) } else { unsetenv("TERMINALDB_PEER_EPHEMERAL_IDENTITY") }
            try? FileManager.default.removeItem(at: directory)
        }
        do {
            let message: [String: Any] = ["type": "request", "data": "🙂é\u{1b}[31m", "sequence": 7]
            let encoded = try PeerProtocol.encode(message)
            var fragmented = PeerFrameDecoder()
            var decoded: [[String: Any]] = []
            for byte in encoded { decoded += try fragmented.accept(Data([byte])) }
            try check(decoded.count == 1)
            try check(decoded.first?["data"] as? String == message["data"] as? String)
            var combined = PeerFrameDecoder()
            try check(try combined.accept(encoded + encoded).count == 2)
            let largeText = String(repeating: "界", count: 500_000)
            let largeFrames = try PeerProtocol.encode(["type": "state", "text": largeText])
            var largeDecoder = PeerFrameDecoder()
            var largeMessages: [[String: Any]] = []
            for offset in stride(from: 0, to: largeFrames.count, by: 8191) {
                largeMessages += try largeDecoder.accept(largeFrames.subdata(in: offset..<min(offset + 8191, largeFrames.count)))
            }
            try check(largeMessages.count == 1 && largeMessages.first?["text"] as? String == largeText)
            // The final small wire fragment delivers a large assembled object.
            // Charge that full object to the cross-queue delivery budget.
            try check(largeDecoder.deliveryBytes >= largeText.utf8.count)
            var malformed = PeerFrameDecoder()
            var oversizedRejected = false
            do { _ = try malformed.accept(Data([255, 255, 255, 255])) } catch { oversizedRejected = true }
            try check(oversizedRejected)
            for message in [
                ["type": "message.fragment", "id": UUID().uuidString, "index": 1, "count": 2, "data": "eA=="],
                ["type": "message.fragment", "id": UUID().uuidString, "index": 0, "count": 65, "data": "eA=="]
            ] as [[String: Any]] {
                var decoder = PeerFrameDecoder(), rejected = false
                do { _ = try decoder.accept(PeerProtocol.encode(message)) } catch { rejected = true }
                try check(rejected)
            }
            let budget = PeerQueueBudget()
            try check(budget.reserve(PeerProtocol.maximumQueuedBytes) && !budget.reserve(1))
            budget.release(PeerProtocol.maximumQueuedBytes)
            try check(budget.reserve(1))
            var lease = PeerControlLease()
            let first = lease.acquire("first")
            try check(lease.allows("first", generation: first))
            let second = lease.acquire("second")
            try check(!lease.allows("first", generation: first))
            try check(!lease.allows("second", generation: first))
            try check(lease.allows("second", generation: second))
            lease.release("first")
            try check(lease.allows("second", generation: second))
            lease.release("second")
            try check(!lease.allows("second", generation: second))
            PeerInputRecovery.set("synthetic-session", uncertain: true)
            try check(PeerInputRecovery.contains("synthetic-session"))
            PeerInputRecovery.set("synthetic-session", uncertain: false)
            try check(!PeerInputRecovery.contains("synthetic-session"))
            let receipts = PeerReceipts()
            receipts.remember(principal: "first", request: "same", result: ["accepted": true])
            try check(receipts.result(principal: "first", request: "same")?["accepted"] as? Bool == true)
            try check(receipts.result(principal: "second", request: "same") == nil)
            try check(try PeerEndpoint.parse("[fd00::1]:49377").host == "fd00::1")
            try check(try PeerEndpoint.parse("example.invalid").port == PeerProtocol.defaultPort)
            var credentialsRejected = false
            do { _ = try PeerEndpoint.parse("user:password@example.invalid") } catch { credentialsRejected = true }
            try check(credentialsRejected)
            for host in ["10.1.2.3", "172.16.0.1", "172.31.255.254", "192.168.1.10", "169.254.10.1", "100.64.0.1", "100.127.255.254", "127.0.0.1", "::1", "fd12::1", "fe80::1%en0", "::ffff:192.168.1.10"] {
                try check(PrivateNetwork.allows(host))
            }
            for host in ["8.8.8.8", "203.0.113.10", "172.15.255.254", "172.32.0.1", "100.63.255.254", "100.128.0.1", "0.0.0.0", "224.0.0.1", "::", "2001:db8::1", "ff02::1", "::ffff:8.8.8.8"] {
                try check(!PrivateNetwork.allows(host))
                var rejected = false
                do { _ = try PeerEndpoint.parse(host.contains(":") ? "[\(host)]" : host) } catch { rejected = true }
                try check(rejected)
            }
            try check(try PrivateNetwork.resolve(PeerEndpoint.parse("localhost")).allSatisfy { PrivateNetwork.allows($0.ipAddress ?? "") })
            try check(PrivateNetwork.interfaceAddresses().allSatisfy(PrivateNetwork.allows))
            let legacyID = String(repeating: "a", count: 64)
            let oldSettings: [String: Any] = ["peers": [legacyID: ["id": legacyID, "name": "Synthetic migration", "pairedAt": 0,
                "endpoints": [["host": "192.168.1.10", "port": 49377, "scope": "lan"], ["host": "203.0.113.10", "port": 49377, "scope": "internet"]]]],
                "listenPort": 49377, "allowForwarding": true, "publicEndpoints": [["host": "203.0.113.10", "port": 49377, "scope": "internet"]]]
            try PeerPaths.save(JSONSerialization.data(withJSONObject: oldSettings), name: "trust.json")
            let migrated = try PeerTrustStore()
            try check(migrated.settings.peers[legacyID]?.endpoints.count == 1)
            let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: PeerPaths.file("trust.json"))) as! [String: Any]
            try check(stored["allowForwarding"] == nil && stored["publicEndpoints"] == nil)
            try migrated.update { $0.peers.removeAll() }
            let nativeServer = TDBSessionServer()
            let nativeSession = UUID().uuidString
            var deliveredInput = Data()
            nativeServer.requestHandler = { message, reply in
                switch message["operation"] as? String {
                case "session.create": reply(["sessionId": nativeSession])
                case "session.snapshot":
                    nativeServer.publishToClient(["type": "snapshot.end", "sessionId": nativeSession], clientID: message["deliveryClientId"] as! String)
                    reply(["accepted": true])
                case "terminal.input":
                    deliveredInput.append(Data(base64Encoded: message["data"] as? String ?? "") ?? Data()); reply(["accepted": true])
                default: reply(["accepted": true])
                }
            }
            try nativeServer.start()
            let nativeClient = TDBSessionClient()
            var nativeReady = false
            nativeClient.connect { _ in nativeClient.create("") { _ in nativeClient.request("session.snapshot", payload: [:]) { _ in nativeReady = true } } }
            let nativeDeadline = PeerClock.now + 10
            while !nativeReady && PeerClock.now < nativeDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            try check(nativeReady)
            let burst = Data(String(repeating: "type-123_/", count: 200).utf8)
            var acceptedBurst = true
            for byte in burst { acceptedBurst = nativeClient.sendInput(Data([byte])) && acceptedBurst }
            while deliveredInput.count < burst.count && PeerClock.now < nativeDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            try check(acceptedBurst && deliveredInput == burst && !nativeClient.inputUncertain)
            nativeClient.close(); nativeServer.requestHandler = nil
            let a: PeerDeviceIdentity
            if ProcessInfo.processInfo.environment["TERMINALDB_PEER_VERIFY_KEYCHAIN"] == "1" {
                unsetenv("TERMINALDB_PEER_EPHEMERAL_IDENTITY")
                a = try PeerDeviceIdentity()
                let renewed = try PeerDeviceIdentity()
                try check(a.fingerprint == renewed.fingerprint)
                let label = "TerminalDB disposable identity QA " + UUID().uuidString
                defer { SecItemDelete(PeerSoftwareIdentity.query(label: label) as CFDictionary) }
                let software = try PeerSoftwareIdentity.create(label: label)
                let sample = Data("disposable signing test".utf8)
                let signature = SecKeyCreateSignature(software, .ecdsaSignatureMessageX962SHA256, sample as CFData, nil)!
                try check(SecKeyCopyExternalRepresentation(software, nil) == nil &&
                    SecKeyVerifySignature(SecKeyCopyPublicKey(software)!, .ecdsaSignatureMessageX962SHA256, sample as CFData, signature, nil))
                setenv("TERMINALDB_PEER_EPHEMERAL_IDENTITY", "1", 1)
            } else { a = try PeerDeviceIdentity() }
            let b = try PeerDeviceIdentity(), c = try PeerDeviceIdentity()
            try check(a.fingerprint != b.fingerprint && b.fingerprint != c.fingerprint)
            let ta = try PeerTrustStore(), tb = try PeerTrustStore()
            func trusted(_ identity: PeerDeviceIdentity) -> TrustedPeer {
                TrustedPeer(id: identity.fingerprint, name: "Test", endpoints: [], pairedAt: Date())
            }
            try ta.update { $0.peers[b.fingerprint] = trusted(b); $0.peers[c.fingerprint] = trusted(c) }
            try tb.update { $0.peers[a.fingerprint] = trusted(a) }
            let na = PeerTLSNetwork(identity: a, trust: ta, gate: PeerPairingGate())
            let nb = PeerTLSNetwork(identity: b, trust: tb, gate: PeerPairingGate())
            var listeners = 0, failure = false
            try nb.listen(port: 0) { if $0 != nil { failure = true }; listeners += 1 }
            func spin(_ done: () -> Bool, timeout: TimeInterval = 15) -> Bool {
                let end = PeerClock.now + timeout
                while !done() && PeerClock.now < end {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                }
                return done()
            }
            try check(spin { listeners == 1 } && !failure)
            let eb = PeerEndpoint(host: "127.0.0.1", port: nb.listeningPort, scope: "lan")
            var received = false, direct: PeerTLSLink?
            nb.accepted = { link in link.receive = { link.send($0) } }
            na.connect(endpoint: eb, expected: b.fingerprint, pairing: false) { result in
                if case .success(let link) = result {
                    direct = link
                    link.receive = { received = $0["probe"] as? String == "native-peer-test" }
                    link.send(["probe": "native-peer-test"])
                } else { failure = true }
            }
            try check(spin { received || failure } && received)
            direct?.close()
            var wrongPinRejected = false
            na.connect(endpoint: eb, expected: c.fingerprint, pairing: false) { result in
                if case .failure = result { wrongPinRejected = true }
            }
            try check(spin { wrongPinRejected })
            var rebound = false
            nb.refreshListeners { error in rebound = error == nil }
            try check(spin { rebound })
            var recovered = 0
            for index in 0..<35 {
                var echoed = false
                na.connect(endpoint: eb, expected: b.fingerprint, pairing: false) { result in
                    if case .success(let link) = result {
                        link.receive = { message in
                            if message["recovery"] as? Int == index { echoed = true; link.close() }
                        }
                        link.send(["recovery": index])
                    }
                }
                if spin({ echoed && na.activeConnectionCount == 0 && nb.activeConnectionCount == 0 }) {
                    recovered += 1
                } else { throw PeerFailure("Private-network recovery did not finish.") }
            }
            try check(recovered == 35)
            let rawGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            var unauthenticated: [Channel] = []
            defer {
                for channel in unauthenticated { channel.close(promise: nil) }
                try? rawGroup.syncShutdownGracefully()
            }
            for _ in 0..<40 {
                let channel = try ClientBootstrap(group: rawGroup)
                    .connectTimeout(.seconds(3))
                    .connect(to: SocketAddress(ipAddress: "127.0.0.1", port: nb.listeningPort)).wait()
                unauthenticated.append(channel)
            }
            try check(spin { nb.activeConnectionCount == PeerProtocol.maximumConnections })
            try check(spin({ unauthenticated.allSatisfy { !$0.isActive } && nb.activeConnectionCount == 0 }, timeout: 15))
            var publicRejected = false
            na.connect(endpoint: PeerEndpoint(host: "203.0.113.10", port: 49377, scope: "manual"), expected: b.fingerprint, pairing: false) { result in
                if case .failure = result { publicRejected = true }
            }
            try check(spin { publicRejected } && na.activeConnectionCount == 0)
            try tb.update { $0.peers.removeValue(forKey: a.fingerprint) }
            var revocationRejected = false
            var unauthorizedAccepted = false
            var revoked: PeerTLSLink?
            nb.accepted = { link in unauthorizedAccepted = true; link.close() }
            na.connect(endpoint: eb, expected: b.fingerprint, pairing: false) { result in
                if case .failure = result { revocationRejected = true }
                if case .success(let link) = result {
                    revoked = link
                    link.disconnected = { revocationRejected = true }
                    link.send(["probe": "revoked"])
                }
            }
            try check(spin { revocationRejected } && !unauthorizedAccepted)
            revoked?.close()
            print("TerminalDB native peer regression checks: \(checks) passed")
            return true
        } catch {
            // Deliberately omit key values, payloads and handshake material.
            let detail = (error as? PeerFailure)?.message ?? "Transport or certificate operation failed."
            fputs("FAIL native peer regression check after \(checks) successful checks: \(detail)\n", stderr)
            return false
        }
    }
}
