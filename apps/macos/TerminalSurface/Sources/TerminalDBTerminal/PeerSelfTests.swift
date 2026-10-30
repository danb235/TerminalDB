import Foundation
import Security

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
            try check(try PeerEndpoint.parse("[2001:db8::1]:49377").host == "2001:db8::1")
            try check(try PeerEndpoint.parse("example.invalid").port == PeerProtocol.defaultPort)
            var credentialsRejected = false
            do { _ = try PeerEndpoint.parse("user:password@example.invalid") } catch { credentialsRejected = true }
            try check(credentialsRejected)
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
            let ta = try PeerTrustStore(), tb = try PeerTrustStore(), tc = try PeerTrustStore()
            func trusted(_ identity: PeerDeviceIdentity) -> TrustedPeer {
                TrustedPeer(id: identity.fingerprint, name: "Test", endpoints: [], pairedAt: Date())
            }
            try ta.update { $0.peers[b.fingerprint] = trusted(b); $0.peers[c.fingerprint] = trusted(c) }
            try tb.update { $0.peers[a.fingerprint] = trusted(a) }
            try tc.update { $0.peers[a.fingerprint] = trusted(a) }
            let na = PeerTLSNetwork(identity: a, trust: ta, gate: PeerPairingGate())
            let nb = PeerTLSNetwork(identity: b, trust: tb, gate: PeerPairingGate())
            let nc = PeerTLSNetwork(identity: c, trust: tc, gate: PeerPairingGate())
            var listeners = 0, failure = false
            try nb.listen(port: 0) { if $0 != nil { failure = true }; listeners += 1 }
            try nc.listen(port: 0) { if $0 != nil { failure = true }; listeners += 1 }
            func spin(_ done: () -> Bool, timeout: TimeInterval = 15) -> Bool {
                let end = PeerClock.now + timeout
                while !done() && PeerClock.now < end {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                }
                return done()
            }
            try check(spin { listeners == 2 } && !failure)
            let eb = PeerEndpoint(host: "127.0.0.1", port: nb.listeningPort, scope: "lan")
            let ec = PeerEndpoint(host: "127.0.0.1", port: nc.listeningPort, scope: "lan")
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
            nb.accepted = { link in
                link.receive = { message in
                    if message["type"] as? String == "tunnel.open", message["target"] as? String == c.fingerprint {
                        nb.forward(link, endpoints: [ec])
                    } else { link.close() }
                }
            }
            var destinationSeesOrigin = false, forwarded: PeerTLSLink?, forwardedEcho = false
            nc.accepted = { link in
                destinationSeesOrigin = link.peerID == a.fingerprint
                link.receive = { link.send($0) }
            }
            na.connectForwarded(endpoint: eb, gateway: b.fingerprint, target: c.fingerprint) { result in
                if case .success(let link) = result {
                    forwarded = link
                    link.receive = { forwardedEcho = $0["probe"] as? String == "end-to-end" }
                    link.send(["probe": "end-to-end"])
                } else { failure = true }
            }
            try check(spin { forwardedEcho || failure } && forwardedEcho && destinationSeesOrigin)
            forwarded?.close()
            var recovered = 0
            for index in 0..<35 {
                var echoed = false
                na.connectForwarded(endpoint: eb, gateway: b.fingerprint, target: c.fingerprint) { result in
                    if case .success(let link) = result {
                        link.receive = { message in
                            if message["recovery"] as? Int == index { echoed = true; link.close() }
                        }
                        link.send(["recovery": index])
                    }
                }
                // Wait for closure through all forwarding hops before starting
                // the next recovery. Echo receipt alone precedes asynchronous
                // close propagation and can overlap the admission limit on CI.
                if spin({ echoed && na.activeConnectionCount == 0 && nb.activeConnectionCount == 0 && nc.activeConnectionCount == 0 }) {
                    recovered += 1
                } else {
                    throw PeerFailure("Forwarded recovery \(index + 1) did not finish: origin \(na.activeConnectionCount), gateway \(nb.activeConnectionCount), destination \(nc.activeConnectionCount) connections remain.")
                }
            }
            try check(recovered == 35)
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
