import Foundation
import Security
import Darwin

protocol PeerConnection: AnyObject {
    var id: String { get }
    func send(_ message: [String: Any])
    func close()
}

// All descriptor state is serialized on wireQueue. Delivery is always on the
// main queue, shared with session state. Slow readers have bounded buffers.
final class PeerLocalConnection: PeerConnection {
    let id = UUID().uuidString
    private var fd: Int32
    private let wireQueue = DispatchQueue(label: "com.terminaldb.peer.local")
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var decoder = PeerFrameDecoder()
    private var output = Data()
    private var offset = 0
    private var stopped = false
    private let sendBudget = PeerQueueBudget()
    private let deliveryBudget = PeerQueueBudget()
    var receive: (([String: Any]) -> Void)?
    var disconnected: (() -> Void)?

    init(fd: Int32) {
        self.fd = fd
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
    }
    deinit { if fd >= 0 { Darwin.close(fd) } }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: wireQueue)
        reader = source
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.resume()
    }

    func send(_ message: [String: Any]) {
        guard let frame = try? PeerProtocol.encode(message) else { close(); return }
        guard sendBudget.reserve(frame.count) else { close(); return }
        wireQueue.async {
            defer { self.sendBudget.release(frame.count) }
            guard !self.stopped else { return }
            guard self.output.count - self.offset + frame.count <= PeerProtocol.maximumQueuedBytes else {
                self.stop(); return
            }
            if self.offset > 0 { self.output.removeFirst(self.offset); self.offset = 0 }
            self.output.append(frame)
            self.flush()
        }
    }

    func close() { wireQueue.async { self.stop() } }

    private func stop() {
        guard !stopped else { return }
        stopped = true
        reader?.cancel(); reader = nil
        writer?.cancel(); writer = nil
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd); fd = -1
        output.removeAll()
        DispatchQueue.main.async {
            let callback = self.disconnected
            self.disconnected = nil; self.receive = nil
            callback?()
        }
    }

    private func readAvailable() {
        var bytes = [UInt8](repeating: 0, count: 65_536)
        // Yield after a bounded batch rather than allowing a flooding peer to
        // monopolize a serial queue indefinitely.
        for _ in 0..<16 {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 {
                do {
                    let messages = try decoder.accept(Data(bytes.prefix(count)))
                    let cost = max(count, decoder.deliveryBytes)
                    guard deliveryBudget.reserve(cost) else { stop(); return }
                    DispatchQueue.main.async {
                        defer { self.deliveryBudget.release(cost) }
                        for message in messages { self.receive?(message) }
                    }
                } catch { stop(); return }
            } else if count < 0 && errno == EINTR { continue }
            else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            else { stop(); return }
        }
    }

    private func flush() {
        while offset < output.count {
            let count = output.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            if count > 0 { offset += count; continue }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                if writer == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: wireQueue)
                    writer = source
                    source.setEventHandler { [weak self] in self?.flush() }
                    source.resume()
                    wireQueue.asyncAfter(deadline: .now() + 10) { [weak self, weak source] in
                        guard let self, self.writer === source else { return }
                        self.stop()
                    }
                }
                return
            }
            stop(); return
        }
        output.removeAll(keepingCapacity: true); offset = 0
        writer?.cancel(); writer = nil
    }

    static func connect(_ name: String) throws -> PeerLocalConnection {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw PeerFailure("Could not open the session connection.") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = PeerPaths.file(name + ".sock").path
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(descriptor); throw PeerFailure("The session socket path is too long.")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 104) { _ = strlcpy($0, path, 104) }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { Darwin.close(descriptor); throw PeerFailure("The background session service is unavailable.") }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(descriptor, &uid, &gid) == 0, uid == geteuid() else {
            Darwin.close(descriptor); throw PeerFailure("The session service belongs to another macOS user.")
        }
        return PeerLocalConnection(fd: descriptor)
    }
}

final class PeerLocalListener {
    private var fd: Int32 = -1
    private var lockFD: Int32 = -1
    private var source: DispatchSourceRead?
    private var connections: [String: PeerLocalConnection] = [:]
    let secret: String
    let name: String
    var accepted: ((PeerLocalConnection, [String: Any]) -> Void)?

    init(name: String) throws {
        self.name = name
        try PeerPaths.prepare()
        lockFD = Darwin.open(PeerPaths.file(name + ".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            throw PeerFailure("The background service is already running.")
        }
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
            throw PeerFailure("Could not create the local connection secret.")
        }
        secret = Data(random).base64EncodedString()
        try PeerPaths.save(Data(secret.utf8), name: name + ".secret")
        fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PeerFailure("Could not open the background service socket.") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = PeerPaths.file(name + ".sock").path
        guard path.utf8.count < 104 else { throw PeerFailure("The session socket path is too long.") }
        withUnsafeMutablePointer(to: &address.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: 104) { _ = strlcpy($0, path, 104) }
        }
        unlink(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
            throw PeerFailure("Could not listen for native session clients.")
        }
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        self.source = source
        source.setEventHandler { [weak self] in self?.accept() }
        source.resume()
    }

    private func accept() {
        let descriptor = Darwin.accept(fd, nil, nil)
        guard descriptor >= 0 else { return }
        var uid: uid_t = 0, gid: gid_t = 0
        guard connections.count < PeerProtocol.maximumConnections,
              getpeereid(descriptor, &uid, &gid) == 0, uid == geteuid() else {
            Darwin.close(descriptor); return
        }
        let connection = PeerLocalConnection(fd: descriptor)
        connections[connection.id] = connection
        var authenticated = false
        connection.receive = { [weak self, weak connection] message in
            guard let self, let connection else { return }
            guard !authenticated else { return }
            guard message["type"] as? String == "hello", message["secret"] as? String == self.secret,
                  message["version"] as? Int == PeerProtocol.version else { connection.close(); return }
            authenticated = true
            self.accepted?(connection, message)
        }
        connection.disconnected = { [weak self, weak connection] in
            guard let connection else { return }
            self?.connections.removeValue(forKey: connection.id)
        }
        connection.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { if !authenticated { connection.close() } }
    }
}
