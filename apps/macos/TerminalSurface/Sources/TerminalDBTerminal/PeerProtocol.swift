import Foundation
import CryptoKit
import Darwin

// Native peer protocol. There is no cloud route, room password, or implicit
// trust inherited from a connection's address. The authenticated transport
// supplies the principal; clients cannot choose it in a request body.
enum PeerProtocol {
    static let version = 1
    static let maximumFrame = 1_048_576
    static let maximumMessage = 8 * maximumFrame
    static let maximumQueuedBytes = 16 * maximumFrame
    static let serviceType = "_terminaldb._tcp."
    static let defaultPort = 49377
    static let maximumConnections = 32

    static func encode(_ message: [String: Any]) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
        guard body.count <= maximumMessage else { throw PeerFailure("The message exceeds the connection limit.") }
        if body.count <= maximumFrame { return frame(body) }
        let id = UUID().uuidString
        let chunkSize = 128 * 1024
        let count = (body.count + chunkSize - 1) / chunkSize
        var result = Data()
        for index in 0..<count {
            let chunk = body.subdata(in: index * chunkSize..<min((index + 1) * chunkSize, body.count))
            let part: [String: Any] = ["type": "message.fragment", "id": id, "index": index,
                                      "count": count, "data": chunk.base64EncodedString()]
            result.append(frame(try JSONSerialization.data(withJSONObject: part)))
        }
        return result
    }
    private static func frame(_ body: Data) -> Data {
        var length = UInt32(body.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        return frame
    }

    static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func error(_ text: String, request: String? = nil) -> [String: Any] {
        var result: [String: Any] = ["type": "error", "detail": text]
        if let request { result["requestId"] = request }
        return result
    }
}

struct PeerFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct PeerFrameDecoder {
    private(set) var deliveryBytes = 0
    private var pending = Data()
    private var logicalID: String?
    private var logicalData = Data()
    private var logicalNext = 0
    private var logicalCount = 0
    private var logicalDeadline: TimeInterval = 0
    mutating func accept(_ bytes: Data) throws -> [[String: Any]] {
        deliveryBytes = 0
        guard bytes.count <= PeerProtocol.maximumQueuedBytes,
              pending.count + bytes.count <= PeerProtocol.maximumQueuedBytes else {
            throw PeerFailure("The connection exceeded its receive buffer.")
        }
        pending.append(bytes)
        var result: [[String: Any]] = []
        while pending.count >= 4 {
            let length = pending.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard length > 1, length <= PeerProtocol.maximumFrame else {
                throw PeerFailure("The connection sent an invalid frame length.")
            }
            guard pending.count >= length + 4 else { break }
            let body = pending.subdata(in: 4..<(length + 4))
            guard let message = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                throw PeerFailure("The connection sent an invalid message.")
            }
            if message["type"] as? String == "message.fragment" {
                guard let id = message["id"] as? String, UUID(uuidString: id) != nil,
                      let index = message["index"] as? Int, let count = message["count"] as? Int,
                      count > 0, count <= 64, let value = message["data"] as? String,
                      let chunk = Data(base64Encoded: value), chunk.count <= 128 * 1024 else {
                    throw PeerFailure("Invalid message fragment.")
                }
                if logicalID == nil {
                    guard index == 0 else { throw PeerFailure("Incomplete message fragments.") }
                    logicalID = id; logicalNext = 0; logicalCount = count
                    logicalDeadline = PeerClock.now + 60
                }
                guard logicalID == id, logicalNext == index, logicalCount == count,
                      PeerClock.now <= logicalDeadline,
                      logicalData.count + chunk.count <= PeerProtocol.maximumMessage else {
                    throw PeerFailure("Out-of-order or oversized message fragments.")
                }
                logicalData.append(chunk); logicalNext += 1
                if logicalNext == logicalCount {
                    guard let assembled = try JSONSerialization.jsonObject(with: logicalData) as? [String: Any],
                          assembled["type"] as? String != "message.fragment" else {
                        throw PeerFailure("Invalid assembled message.")
                    }
                    deliveryBytes += max(256, logicalData.count)
                    guard deliveryBytes <= PeerProtocol.maximumQueuedBytes else { throw PeerFailure("The connection exceeded its delivery buffer.") }
                    result.append(assembled)
                    logicalID = nil; logicalData.removeAll(keepingCapacity: false)
                }
            } else {
                guard logicalID == nil else { throw PeerFailure("An incomplete message was interrupted.") }
                deliveryBytes += max(256, length)
                guard deliveryBytes <= PeerProtocol.maximumQueuedBytes else { throw PeerFailure("The connection exceeded its delivery buffer.") }
                result.append(message)
            }
            pending.removeSubrange(0..<(length + 4))
        }
        return result
    }
}

// A generation fences old writers after takeover. Request receipts survive
// reconnects, but input is never automatically retried by the client.
struct PeerControlLease {
    private(set) var owner: String?
    private(set) var generation: UInt64 = 0
    mutating func acquire(_ principal: String) -> UInt64 {
        if owner != principal { generation &+= 1; owner = principal }
        return generation
    }
    mutating func release(_ principal: String) {
        if owner == principal { owner = nil; generation &+= 1 }
    }
    func allows(_ principal: String, generation candidate: UInt64) -> Bool {
        owner == principal && generation == candidate
    }
}

final class PeerReceipts {
    private var entries: [String: [String: Any]] = [:]
    private var order: [String] = []
    private var sizes: [String: Int] = [:]
    private var bytes = 0
    func result(principal: String, request: String) -> [String: Any]? { entries[principal + ":" + request] }
    func remember(principal: String, request: String, result: [String: Any]) {
        let key = principal + ":" + request
        if entries[key] == nil { order.append(key) }
        bytes -= sizes[key] ?? 0
        let size = (try? JSONSerialization.data(withJSONObject: result).count) ?? PeerProtocol.maximumMessage
        sizes[key] = size; bytes += size
        entries[key] = result
        while order.count > 4096 || bytes > 16 * PeerProtocol.maximumFrame {
            let oldest = order.removeFirst()
            bytes -= sizes.removeValue(forKey: oldest) ?? 0
            entries.removeValue(forKey: oldest)
        }
    }
}

enum PeerPaths {
    static var root: URL {
        if let override = ProcessInfo.processInfo.environment["TERMINALDB_PEER_STATE_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TerminalDB/Peers", isDirectory: true)
    }
    static func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }
    static func file(_ name: String) -> URL { root.appendingPathComponent(name) }
    static func save(_ data: Data, name: String) throws {
        try prepare()
        try data.write(to: file(name), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(name).path)
    }
}

// Includes work queued between transport queues and the main actor, so a fast
// sender cannot bypass the wire-buffer bound by filling dispatch callbacks.
final class PeerQueueBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0
    func reserve(_ count: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard count >= 0, count <= PeerProtocol.maximumQueuedBytes - bytes else { return false }
        bytes += count; return true
    }
    func release(_ count: Int) { lock.lock(); bytes -= count; lock.unlock() }
}

// Unlike uptime clocks that pause in sleep, this monotonic clock expires pairing
// windows and queued input while a Mac is asleep.
enum PeerClock {
    private static let scale: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()
    static var now: Double { Double(mach_continuous_time()) * scale }
}
