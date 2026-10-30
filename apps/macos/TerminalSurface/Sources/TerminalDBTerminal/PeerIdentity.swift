import Foundation
import Security
import CryptoKit
import X509
import NIOCore
import NIOSSL
import Darwin

enum PeerLAN {
    static func contains(_ original: String) -> Bool {
        var host = original
        if host.hasPrefix("::ffff:") { host = String(host.dropFirst(7)) }
        host = host.components(separatedBy: "%").first ?? host
        var ipv4 = in_addr(), ipv6 = in6_addr()
        let family: Int32
        if inet_pton(AF_INET, host, &ipv4) == 1 { family = AF_INET }
        else if inet_pton(AF_INET6, host, &ipv6) == 1 { family = AF_INET6 }
        else { return false }
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return false }
        defer { freeifaddrs(interfaces) }
        var current = interfaces
        while let item = current {
            defer { current = item.pointee.ifa_next }
            guard let address = item.pointee.ifa_addr, let mask = item.pointee.ifa_netmask,
                  Int32(address.pointee.sa_family) == family else { continue }
            if item.pointee.ifa_flags & UInt32(IFF_LOOPBACK) != 0 &&
                ProcessInfo.processInfo.environment["TERMINALDB_PEER_EPHEMERAL_IDENTITY"] != "1" { continue }
            if family == AF_INET {
                let local = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
                let netmask = UnsafeRawPointer(mask).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
                if netmask != 0 && (local & netmask) == (ipv4.s_addr & netmask) { return true }
            } else {
                let local = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
                let netmask = UnsafeRawPointer(mask).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
                let a = withUnsafeBytes(of: local) { Array($0) }
                let b = withUnsafeBytes(of: ipv6) { Array($0) }
                let m = withUnsafeBytes(of: netmask) { Array($0) }
                if m.contains(where: { $0 != 0 }) && zip(zip(a, b), m).allSatisfy({ ($0.0.0 & $0.1) == ($0.0.1 & $0.1) }) { return true }
            }
        }
        return false
    }
}

struct PeerEndpoint: Codable, Equatable {
    var host: String
    var port: Int
    var scope: String
    static func parse(_ text: String, scope: String = "internet") throws -> PeerEndpoint {
        guard let components = URLComponents(string: "tls://" + text),
              let host = components.host, !host.isEmpty, host.utf8.count <= 253,
              components.user == nil, components.password == nil,
              components.path.isEmpty, components.query == nil, components.fragment == nil else {
            throw PeerFailure("Enter an address and port, for example 203.0.113.10:49377 or [2001:db8::1]:49377.")
        }
        let port = components.port ?? PeerProtocol.defaultPort
        guard (1...65535).contains(port) else { throw PeerFailure("The port must be between 1 and 65535.") }
        let normalizedHost = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        return PeerEndpoint(host: normalizedHost, port: port, scope: scope)
    }
    var display: String { (host.contains(":") ? "[\(host)]" : host) + ":\(port)" }
}

struct TrustedPeer: Codable {
    var id: String
    var name: String
    var endpoints: [PeerEndpoint]
    var pairedAt: Date
}

struct PeerSettings: Codable {
    var peers: [String: TrustedPeer] = [:]
    var listenPort = PeerProtocol.defaultPort
    var allowForwarding = false
    var publicEndpoints: [PeerEndpoint] = []
    var pendingRevocations: [String: [String]]?
}

final class PeerTrustStore {
    private let lock = NSLock()
    private var value: PeerSettings
    init() throws {
        try PeerPaths.prepare()
        if let data = try? Data(contentsOf: PeerPaths.file("trust.json")) {
            value = try JSONDecoder().decode(PeerSettings.self, from: data)
        } else { value = PeerSettings() }
    }
    var settings: PeerSettings { lock.lock(); defer { lock.unlock() }; return value }
    func contains(_ id: String) -> Bool { settings.peers[id] != nil }
    func update(_ block: (inout PeerSettings) throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        var next = value
        try block(&next)
        guard next.peers.count <= 128 else { throw PeerFailure("Remove an unused paired device before adding another.") }
        try PeerPaths.save(try JSONEncoder().encode(next), name: "trust.json")
        value = next
    }
}

final class PeerDeviceIdentity {
    private let key: SecKey?
    private let enclaveKey: SecureEnclave.P256.Signing.PrivateKey?
    let certificate: NIOSSLCertificate
    let fingerprint: String
    var hardwareBacked: Bool { enclaveKey != nil }
    private let signingQueue = DispatchQueue(label: "com.terminaldb.peer.signing")

    init() throws {
        let testing = ProcessInfo.processInfo.environment["TERMINALDB_PEER_EPHEMERAL_IDENTITY"] == "1"
        let tag = Data("com.terminaldb.peer.identity.v1".utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassKey,
            kSecAttrLabel as String: "TerminalDB paired workstation identity v1", kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate, kSecReturnRef as String: true]
        var stored: CFTypeRef?
        let legacyStatus = testing ? errSecItemNotFound : SecItemCopyMatching(query as CFDictionary, &stored)
        let wrappedQuery: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.terminaldb.peer.identity.v1", kSecAttrAccount as String: "enclave",
            kSecReturnData as String: true]
        var wrapped: CFTypeRef?
        let wrappedStatus = testing ? errSecItemNotFound : SecItemCopyMatching(wrappedQuery as CFDictionary, &wrapped)
        let privateKey: Certificate.PrivateKey
        if wrappedStatus == errSecSuccess, let data = wrapped as? Data {
            let restored = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data)
            enclaveKey = restored; key = nil; privateKey = Certificate.PrivateKey(restored)
        } else if wrappedStatus != errSecItemNotFound {
            throw PeerFailure("Unlock this Mac’s Keychain and allow TerminalDB to use its device identity, then reopen the app.")
        } else if legacyStatus == errSecSuccess {
            let restored = stored as! SecKey
            guard SecKeyCopyExternalRepresentation(restored, nil) == nil else { throw PeerFailure("This device key is not protected against export. Remove its pairings before replacing the identity.") }
            key = restored; enclaveKey = nil; privateKey = try Certificate.PrivateKey(restored)
        } else if legacyStatus != errSecItemNotFound {
            throw PeerFailure("macOS denied access to the device key. Unlock Keychain and reopen TerminalDB.")
        } else if !testing && SecureEnclave.isAvailable {
            // CryptoKit's documented representation is an encrypted enclave
            // handle. The private key never leaves this Mac's Secure Enclave.
            // Store the handle as a local Keychain item, using Apple's supported
            // API rather than depending on private token attributes.
            let generated = try SecureEnclave.P256.Signing.PrivateKey()
            var item = wrappedQuery
            item.removeValue(forKey: kSecReturnData as String)
            item[kSecValueData as String] = generated.dataRepresentation
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            item[kSecAttrSynchronizable as String] = false
            item[kSecAttrLabel as String] = "TerminalDB device identity"
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw PeerFailure("macOS could not save the device identity. Unlock Keychain and reopen TerminalDB.")
            }
            enclaveKey = generated; key = nil; privateKey = Certificate.PrivateKey(generated)
        } else {
            if !testing {
                let generated = try PeerSoftwareIdentity.create(label: "TerminalDB paired workstation identity v1")
                key = generated; enclaveKey = nil; privateKey = try Certificate.PrivateKey(generated)
            } else {
            let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeySizeInBits as String: 256, kSecPrivateKeyAttrs as String: [
                    kSecAttrIsPermanent as String: !testing, kSecAttrApplicationTag as String: tag,
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]]
            var error: Unmanaged<CFError>?
            guard let generated = SecKeyCreateRandomKey(attrs as CFDictionary, &error) else {
                throw PeerFailure("macOS could not create the peer identity in Keychain.")
            }
            key = generated; enclaveKey = nil; privateKey = try Certificate.PrivateKey(generated)
            }
        }
        let name = try DistinguishedName { CommonName("TerminalDB Peer") }
        let cert = try Certificate(
            version: .v3, serialNumber: .init(), publicKey: privateKey.publicKey,
            notValidBefore: Date().addingTimeInterval(-300),
            notValidAfter: Date().addingTimeInterval(366 * 86400),
            issuer: name, subject: name, signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
                try ExtendedKeyUsage([.serverAuth, .clientAuth])
            }, issuerPrivateKey: privateKey)
        certificate = try NIOSSLCertificate(bytes: Array(cert.serializeAsPEM().pemString.utf8), format: .pem)
        fingerprint = try Self.fingerprint(certificate)
    }

    static func fingerprint(_ certificate: NIOSSLCertificate) throws -> String {
        PeerProtocol.fingerprint(Data(try certificate.extractPublicKey().toSPKIBytes()))
    }

    func context(server: Bool) throws -> NIOSSLContext {
        let privateKey = NIOSSLPrivateKey(customPrivateKey: PeerSigningKey(key: key, enclaveKey: enclaveKey, id: fingerprint, queue: signingQueue))
        var configuration = server
            ? TLSConfiguration.makeServerConfiguration(certificateChain: [.certificate(certificate)], privateKey: .privateKey(privateKey))
            : TLSConfiguration.makeClientConfiguration()
        configuration.certificateChain = [.certificate(certificate)]
        configuration.privateKey = .privateKey(privateKey)
        configuration.minimumTLSVersion = .tlsv13
        configuration.maximumTLSVersion = .tlsv13
        configuration.certificateVerification = .noHostnameVerification
        configuration.applicationProtocols = ["terminaldb-peer/1"]
        return try NIOSSLContext(configuration: configuration)
    }
}

private struct PeerSigningKey: NIOSSLCustomPrivateKey, Hashable, @unchecked Sendable {
    let key: SecKey?
    let enclaveKey: SecureEnclave.P256.Signing.PrivateKey?
    let id: String
    let queue: DispatchQueue
    var signatureAlgorithms: [NIOSSL.SignatureAlgorithm] { [.ecdsaSecp256R1Sha256] }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func decrypt(channel: Channel, data: ByteBuffer) -> EventLoopFuture<ByteBuffer> {
        channel.eventLoop.makeFailedFuture(PeerFailure("RSA key exchange is disabled."))
    }
    func sign(channel: Channel, algorithm: NIOSSL.SignatureAlgorithm, data: ByteBuffer) -> EventLoopFuture<ByteBuffer> {
        let promise = channel.eventLoop.makePromise(of: ByteBuffer.self)
        let bytes = Data(data.readableBytesView)
        queue.async {
            do {
                guard algorithm == .ecdsaSecp256R1Sha256 else { throw PeerFailure("Unsupported peer signature.") }
                let signature: Data
                if let enclaveKey = self.enclaveKey { signature = try enclaveKey.signature(for: bytes).derRepresentation }
                else if let key = self.key, let result = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, bytes as CFData, nil) as Data? { signature = result }
                else { throw PeerFailure("Keychain could not sign the peer handshake.") }
                var buffer = channel.allocator.buffer(capacity: signature.count)
                buffer.writeBytes(signature); promise.succeed(buffer)
            } catch { promise.fail(PeerFailure("Keychain could not sign the peer handshake.")) }
        }
        return promise.futureResult
    }
}

// Use the traditional macOS Keychain import API for a non-exportable software
// fallback. SecKeyCreateRandomKey ignores non-extractability on persisted legacy
// keys. The existing RFC 5915 P-256 envelope adapts CryptoKit's X9.63
// representation to the legacy import API; signing remains in Security.
enum PeerSoftwareIdentity {
    static func query(label: String) -> [String: Any] {
        [kSecClass as String: kSecClassKey, kSecAttrLabel as String: label,
         kSecAttrKeyClass as String: kSecAttrKeyClassPrivate, kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom]
    }
    static func create(label: String) throws -> SecKey {
        var raw = P256.Signing.PrivateKey().x963Representation
        guard raw.count == 97, raw.first == 4 else { throw PeerFailure("Unexpected P-256 key representation.") }
        // RFC 5915 ECPrivateKey with named prime256v1 parameters and public key.
        var encoded = Data([0x30, 0x77, 0x02, 0x01, 0x01, 0x04, 0x20])
        encoded.append(raw.suffix(32))
        encoded.append(contentsOf: [0xa0, 0x0a, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0xa1, 0x44, 0x03, 0x42, 0x00])
        encoded.append(raw.prefix(65))
        defer { raw.resetBytes(in: 0..<raw.count); encoded.resetBytes(in: 0..<encoded.count) }
        var keychain: SecKeychain?
        guard SecKeychainCopyDefault(&keychain) == errSecSuccess, let keychain else { throw PeerFailure("Unlock this Mac’s Keychain before creating its device identity.") }
        var application: SecTrustedApplication?, access: SecAccess?
        guard SecTrustedApplicationCreateFromPath(nil, &application) == errSecSuccess,
              let application, SecAccessCreate(label as CFString, [application] as CFArray, &access) == errSecSuccess,
              let access else { throw PeerFailure("macOS could not restrict access to the device key.") }
        let retainedAccess = Unmanaged.passRetained(access)
        let usage = Unmanaged.passRetained([kSecAttrCanSign] as CFArray)
        // Omitting the extractable attribute makes the imported key non-exportable.
        let attributes = Unmanaged.passRetained([kSecAttrIsPermanent, kSecAttrIsSensitive] as CFArray)
        defer { retainedAccess.release(); usage.release(); attributes.release() }
        var parameters = SecItemImportExportKeyParameters(version: UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION),
            flags: [], passphrase: nil, alertTitle: nil, alertPrompt: nil, accessRef: retainedAccess,
            keyUsage: usage, keyAttributes: attributes)
        var format = SecExternalFormat.formatOpenSSL, type = SecExternalItemType.itemTypePrivateKey
        var items: CFArray?
        let status = withUnsafePointer(to: &parameters) {
            SecItemImport(encoded as CFData, nil, &format, &type, [], $0, keychain, &items)
        }
        guard status == errSecSuccess, let imported = (items as? [SecKey])?.first,
              let applicationLabel = (SecKeyCopyAttributes(imported) as? [String: Any])?[kSecAttrApplicationLabel as String] else {
            throw PeerFailure("macOS could not import the protected software device key (status \(status)).")
        }
        let importedQuery: [String: Any] = [kSecClass as String: kSecClassKey, kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrApplicationLabel as String: applicationLabel]
        guard SecItemUpdate(importedQuery as CFDictionary, [kSecAttrLabel as String: label] as CFDictionary) == errSecSuccess else {
            SecItemDelete(importedQuery as CFDictionary); throw PeerFailure("macOS could not label the protected device key.")
        }
        var lookup = query(label: label); lookup[kSecReturnRef as String] = true
        var persisted: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &persisted) == errSecSuccess, let persisted,
              SecKeyCopyExternalRepresentation(persisted as! SecKey, nil) == nil else {
            SecItemDelete(importedQuery as CFDictionary); throw PeerFailure("macOS could not protect the device key against export.")
        }
        return persisted as! SecKey
    }
}
