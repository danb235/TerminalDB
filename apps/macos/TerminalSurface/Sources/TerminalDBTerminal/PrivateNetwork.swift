import Foundation
import Darwin
import NIOCore
import Network

final class PrivateNetworkChanges {
    static let notification = Notification.Name("TerminalDBPrivateNetworkChanged")
    static let shared = PrivateNetworkChanges()
    private let monitor = NWPathMonitor()
    private var signature: String?
    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let signature = String(describing: path.status) + ":" +
                path.availableInterfaces.map { String($0.index) }.sorted().joined(separator: ",") + ":" +
                PrivateNetwork.interfaceAddresses().joined(separator: ",")
            DispatchQueue.main.async {
                guard let self else { return }
                let changed = self.signature != nil && self.signature != signature
                self.signature = signature
                if changed {
                    NotificationCenter.default.post(name: Self.notification, object: nil,
                        userInfo: ["available": path.status == .satisfied])
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.terminaldb.private-network.changes"))
    }
}

enum PrivateNetwork {
    // RFC 1918 LANs, link-local links, VPN shared space, IPv6 ULA and loopback.
    // Public interfaces and public DNS answers are never terminal transports.
    static func allows(_ original: String) -> Bool {
        let host = original.components(separatedBy: "%").first ?? original
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            let bytes = withUnsafeBytes(of: v4) { Array($0) }
            return allowsIPv4(bytes)
        }
        guard inet_pton(AF_INET6, host, &v6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: v6) { Array($0) }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }) && bytes[10] == 255 && bytes[11] == 255 {
            return allowsIPv4(Array(bytes.suffix(4)))
        }
        return bytes == Array(repeating: 0, count: 15) + [1] ||
            bytes[0] & 0xfe == 0xfc || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80)
    }
    private static func allowsIPv4(_ bytes: [UInt8]) -> Bool {
        bytes[0] == 10 || bytes[0] == 127 ||
            (bytes[0] == 172 && (16...31).contains(bytes[1])) ||
            (bytes[0] == 192 && bytes[1] == 168) ||
            (bytes[0] == 169 && bytes[1] == 254) ||
            (bytes[0] == 100 && (64...127).contains(bytes[1]))
    }
    static func isNumeric(_ original: String) -> Bool {
        let host = original.components(separatedBy: "%").first ?? original
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
    }
    static func interfaceAddresses() -> [String] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return [] }
        defer { freeifaddrs(interfaces) }
        var current = interfaces, hosts = Set<String>()
        while let item = current {
            defer { current = item.pointee.ifa_next }
            let interfaceName = String(cString: item.pointee.ifa_name)
            if interfaceName.hasPrefix("awdl") || interfaceName.hasPrefix("llw") { continue }
            guard item.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  let address = item.pointee.ifa_addr,
                  address.pointee.sa_family == AF_INET || address.pointee.sa_family == AF_INET6 else { continue }
            var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 {
                let host = String(cString: name)
                if allows(host) { hosts.insert(host) }
            }
        }
        return hosts.sorted { a, b in
            if a == "127.0.0.1" { return b != a }
            if b == "127.0.0.1" { return false }
            return a < b
        }
    }
    // Resolve once off the main thread, filter every answer, then connect to
    // the exact checked sockaddr. A second lookup cannot rebind to a public IP.
    static func resolve(_ endpoint: PeerEndpoint) throws -> [SocketAddress] {
        var hints = addrinfo(), result: UnsafeMutablePointer<addrinfo>?
        hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM; hints.ai_protocol = IPPROTO_TCP
        guard getaddrinfo(endpoint.host, String(endpoint.port), &hints, &result) == 0 else {
            throw PeerFailure("The internal workstation address could not be resolved. Connect the VPN or check its saved address.")
        }
        defer { freeaddrinfo(result) }
        var current = result, addresses = [SocketAddress]()
        while let item = current {
            defer { current = item.pointee.ai_next }
            guard let raw = item.pointee.ai_addr else { continue }
            let address: SocketAddress
            if item.pointee.ai_family == AF_INET {
                address = SocketAddress(UnsafeRawPointer(raw).load(as: sockaddr_in.self))
            } else if item.pointee.ai_family == AF_INET6 {
                address = SocketAddress(UnsafeRawPointer(raw).load(as: sockaddr_in6.self))
            } else { continue }
            if allows(address.ipAddress ?? ""), !addresses.contains(address) { addresses.append(address) }
        }
        guard !addresses.isEmpty else {
            throw PeerFailure("TerminalDB connects only to internal LAN or VPN addresses. Public addresses are not supported.")
        }
        return addresses.sorted { $0.protocol == .inet && $1.protocol != .inet }
    }
}
