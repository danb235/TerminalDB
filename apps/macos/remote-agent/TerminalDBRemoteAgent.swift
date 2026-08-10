import Compression
import CryptoKit
import Darwin
import Foundation
import Security

private let protocolVersion = 1
private let maximumWireBytes = 30_000
private let accountBootstrapCapability = "account-bootstrap-v1"
private let browserCapabilities = [
    "sequenced-input-v1",
    "causal-input-output-v1",
    accountBootstrapCapability,
]
private let localAgentCapabilities = [accountBootstrapCapability]

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func decodeBase64URL(_ value: String) -> Data? {
    var normalized = value.replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    normalized.append(String(repeating: "=", count: (4 - normalized.count % 4) % 4))
    return Data(base64Encoded: normalized)
}

private func randomURLSafe(byteCount: Int) -> String {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return base64URL(Data(bytes))
}

private func sha256URL(_ value: String) -> String {
    base64URL(Data(SHA256.hash(data: Data(value.utf8))))
}

private func jsonData(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw AgentError.invalidResponse
    }
    return value
}

private func deflateIfHelpful(_ plain: Data) -> (data: Data, marker: String) {
    guard plain.count > 64 else { return (plain, "none") }
    var output = [UInt8](repeating: 0, count: plain.count + 64)
    let count = plain.withUnsafeBytes { source in
        output.withUnsafeMutableBytes { destination in
            compression_encode_buffer(
                destination.bindMemory(to: UInt8.self).baseAddress!,
                destination.count,
                source.bindMemory(to: UInt8.self).baseAddress!,
                source.count,
                nil,
                COMPRESSION_ZLIB
            )
        }
    }
    guard count > 0, count + 8 < plain.count else { return (plain, "none") }
    return (Data(output.prefix(count)), "deflate")
}

private func inflateBounded(_ compressed: Data) throws -> Data {
    var output = [UInt8](repeating: 0, count: 256 * 1_024)
    let count = compressed.withUnsafeBytes { source in
        output.withUnsafeMutableBytes { destination in
            compression_decode_buffer(
                destination.bindMemory(to: UInt8.self).baseAddress!,
                destination.count,
                source.bindMemory(to: UInt8.self).baseAddress!,
                source.count,
                nil,
                COMPRESSION_ZLIB
            )
        }
    }
    guard count > 0 else {
        throw AgentError.cryptography("Invalid or excessive compressed payload")
    }
    return Data(output.prefix(count))
}

private enum AgentError: Error, LocalizedError {
    case keyCreation(String)
    case invalidPublicKey
    case invalidResponse
    case server(String)
    case remoteHTTP(statusCode: Int, code: String?, message: String)
    case notEnrolled
    case sessionUnavailable
    case socket(String)
    case cryptography(String)

    var errorDescription: String? {
        switch self {
        case .keyCreation(let value): return "Unable to create the device key: \(value)"
        case .invalidPublicKey: return "The remote public key is invalid."
        case .invalidResponse: return "The remote service returned an invalid response."
        case .server(let value): return value
        case .remoteHTTP(_, _, let message): return message
        case .notEnrolled: return "This Mac is not enrolled for TerminalDB Remote."
        case .sessionUnavailable: return "The remote session is not available."
        case .socket(let value): return "Local remote-agent socket failed: \(value)"
        case .cryptography(let value): return "Remote encryption failed: \(value)"
        }
    }

    var revokesAccountEnrollment: Bool {
        guard case .remoteHTTP(let statusCode, let code, _) = self else { return false }
        return statusCode == 401 && code == "PRINCIPAL_REVOKED"
    }
}

private final class DeviceIdentity {
    private let privateKey: SecKey
    let wasCreated: Bool

    private static func secureEnclaveQuery(for tag: Data) -> [String: Any] {
        [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
        ]
    }

    private static func softwareLabel(for tag: Data) -> String {
        "TerminalDB Remote device \(base64URL(tag))"
    }

    private static func softwareQuery(for tag: Data) -> [String: Any] {
        [
            kSecClass as String: kSecClassKey,
            kSecAttrLabel as String: softwareLabel(for: tag),
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
        ]
    }

    static func delete(applicationTag tag: Data) {
        var secureQuery = secureEnclaveQuery(for: tag)
        secureQuery.removeValue(forKey: kSecReturnRef as String)
        SecItemDelete(secureQuery as CFDictionary)
        var softwareQuery = softwareQuery(for: tag)
        softwareQuery.removeValue(forKey: kSecReturnRef as String)
        SecItemDelete(softwareQuery as CFDictionary)
    }

    private static func isNonExportable(_ key: SecKey) -> Bool {
        var error: Unmanaged<CFError>?
        return SecKeyCopyExternalRepresentation(key, &error) == nil
    }

    private static func softwareKeyDER(from rawKey: Data) throws -> Data {
        // SecKey returns a P-256 private key as X9.63 public bytes followed by
        // the 32-byte private scalar. SecItemImport expects an RFC 5915 / SEC1
        // ECPrivateKey for its OpenSSL format.
        guard rawKey.count == 97, rawKey.first == 0x04 else {
            throw AgentError.keyCreation("unexpected P-256 private-key representation")
        }
        var encoded = Data([
            0x30, 0x77,
            0x02, 0x01, 0x01,
            0x04, 0x20,
        ])
        encoded.append(rawKey.suffix(32))
        encoded.append(contentsOf: [
            0xa0, 0x0a,
            0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07,
            0xa1, 0x44,
            0x03, 0x42, 0x00,
        ])
        encoded.append(rawKey.prefix(65))
        return encoded
    }

    private static func currentApplicationAccess(label: String) throws -> SecAccess {
        var trustedApplication: SecTrustedApplication?
        let trustedStatus = SecTrustedApplicationCreateFromPath(
            nil,
            &trustedApplication
        )
        guard trustedStatus == errSecSuccess, let trustedApplication else {
            throw AgentError.keyCreation(
                SecCopyErrorMessageString(trustedStatus, nil) as String? ??
                    "the remote agent could not establish its Keychain identity"
            )
        }
        var access: SecAccess?
        let accessStatus = SecAccessCreate(
            label as CFString,
            [trustedApplication] as CFArray,
            &access
        )
        guard accessStatus == errSecSuccess, let access else {
            throw AgentError.keyCreation(
                SecCopyErrorMessageString(accessStatus, nil) as String? ??
                    "the remote-agent Keychain access policy could not be created"
            )
        }
        return access
    }

    private static func createNonExportableSoftwareKey(tag: Data) throws -> SecKey {
        let generationAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ]
        var generationError: Unmanaged<CFError>?
        guard let generated = SecKeyCreateRandomKey(
            generationAttributes as CFDictionary,
            &generationError
        ) else {
            throw AgentError.keyCreation(
                generationError?.takeRetainedValue().localizedDescription ??
                    "software P-256 generation failed"
            )
        }
        var exportError: Unmanaged<CFError>?
        guard var rawKey = SecKeyCopyExternalRepresentation(
            generated,
            &exportError
        ) as Data? else {
            throw AgentError.keyCreation(
                exportError?.takeRetainedValue().localizedDescription ??
                    "software P-256 export failed"
            )
        }
        var encodedKey = try softwareKeyDER(from: rawKey)
        defer {
            rawKey.resetBytes(in: 0..<rawKey.count)
            encodedKey.resetBytes(in: 0..<encodedKey.count)
        }

        var defaultKeychain: SecKeychain?
        let keychainStatus = SecKeychainCopyDefault(&defaultKeychain)
        guard keychainStatus == errSecSuccess, let defaultKeychain else {
            throw AgentError.keyCreation(
                SecCopyErrorMessageString(keychainStatus, nil) as String? ??
                    "default Keychain is unavailable"
            )
        }
        let usage: [CFString] = [kSecAttrCanSign, kSecAttrCanDerive]
        // Omitting kSecAttrIsExtractable is what makes an imported macOS
        // Keychain key permanently non-exportable.
        let attributes: [CFString] = [kSecAttrIsPermanent, kSecAttrIsSensitive]
        let retainedUsage = Unmanaged.passRetained(usage as CFArray)
        let retainedAttributes = Unmanaged.passRetained(attributes as CFArray)
        let access = try currentApplicationAccess(label: softwareLabel(for: tag))
        let retainedAccess = Unmanaged.passRetained(access)
        defer {
            retainedUsage.release()
            retainedAttributes.release()
            retainedAccess.release()
        }
        var parameters = SecItemImportExportKeyParameters(
            version: UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION),
            flags: [],
            passphrase: nil,
            alertTitle: nil,
            alertPrompt: nil,
            accessRef: retainedAccess,
            keyUsage: retainedUsage,
            keyAttributes: retainedAttributes
        )
        var format = SecExternalFormat.formatOpenSSL
        var itemType = SecExternalItemType.itemTypePrivateKey
        var importedItems: CFArray?
        let importStatus = withUnsafePointer(to: &parameters) { pointer in
            SecItemImport(
                encodedKey as CFData,
                nil,
                &format,
                &itemType,
                [],
                pointer,
                defaultKeychain,
                &importedItems
            )
        }
        guard importStatus == errSecSuccess,
              let items = importedItems as? [Any],
              let imported = items.first as! SecKey? else {
            throw AgentError.keyCreation(
                SecCopyErrorMessageString(importStatus, nil) as String? ??
                    "non-exportable Keychain import failed"
            )
        }
        let importedAttributes = SecKeyCopyAttributes(imported) as NSDictionary? ?? [:]
        guard let applicationLabel = importedAttributes[kSecAttrApplicationLabel] else {
            throw AgentError.keyCreation("imported Keychain key has no application label")
        }
        let importedQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrApplicationLabel as String: applicationLabel,
        ]
        let labelStatus = SecItemUpdate(
            importedQuery as CFDictionary,
            [kSecAttrLabel as String: softwareLabel(for: tag)] as CFDictionary
        )
        guard labelStatus == errSecSuccess else {
            SecItemDelete(importedQuery as CFDictionary)
            throw AgentError.keyCreation(
                SecCopyErrorMessageString(labelStatus, nil) as String? ??
                    "software Keychain key could not be labeled"
            )
        }
        var found: CFTypeRef?
        let lookupStatus = SecItemCopyMatching(
            softwareQuery(for: tag) as CFDictionary,
            &found
        )
        guard lookupStatus == errSecSuccess,
              let persisted = found as! SecKey?,
              isNonExportable(persisted) else {
            SecItemDelete(importedQuery as CFDictionary)
            throw AgentError.keyCreation("persisted software key was exportable")
        }
        return persisted
    }

    init(applicationTag: Data? = nil) throws {
        if ProcessInfo.processInfo.environment["TERMINALDB_REMOTE_EPHEMERAL_IDENTITY"] == "1" {
            var ephemeralError: Unmanaged<CFError>?
            let attributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeySizeInBits as String: 256,
            ]
            guard let key = SecKeyCreateRandomKey(
                attributes as CFDictionary,
                &ephemeralError
            ) else {
                throw AgentError.keyCreation(
                    ephemeralError?.takeRetainedValue().localizedDescription ?? "ephemeral key"
                )
            }
            privateKey = key
            wasCreated = true
            return
        }
        let tag = applicationTag ??
            Data("com.terminaldb.remote.device.p256.v1".utf8)
        var found: CFTypeRef?
        let secureQuery = Self.secureEnclaveQuery(for: tag)
        if SecItemCopyMatching(secureQuery as CFDictionary, &found) == errSecSuccess,
           let key = found as! SecKey?,
           Self.isNonExportable(key) {
            privateKey = key
            wasCreated = false
            return
        }
        if found != nil {
            var deleteQuery = secureQuery
            deleteQuery.removeValue(forKey: kSecReturnRef as String)
            SecItemDelete(deleteQuery as CFDictionary)
        }
        found = nil
        let softwareQuery = Self.softwareQuery(for: tag)
        if SecItemCopyMatching(softwareQuery as CFDictionary, &found) == errSecSuccess,
           let key = found as! SecKey?,
           Self.isNonExportable(key) {
            privateKey = key
            wasCreated = false
            return
        }

        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            [.privateKeyUsage],
            &accessError
        ) else {
            throw AgentError.keyCreation(accessError?.takeRetainedValue().localizedDescription ?? "access control")
        }
        let secureEnclavePrivateAttributes: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: tag,
            kSecAttrIsExtractable as String: false,
            kSecAttrAccessControl as String: access,
        ]
        var creationError: Unmanaged<CFError>?
        let secureEnclaveAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: secureEnclavePrivateAttributes,
        ]
        if let key = SecKeyCreateRandomKey(secureEnclaveAttributes as CFDictionary, &creationError) {
            privateKey = key
            wasCreated = true
            return
        }
        // Secure Enclave keys use the data-protection Keychain and therefore
        // require a provisioned application identifier. Local open-source
        // builds are ad-hoc signed, so fall back to a non-exportable software
        // key in the traditional macOS Keychain. SecItemImport is used here
        // because the modern key-generation shim ignores non-extractability
        // for traditional Keychain keys on current macOS releases.
        privateKey = try Self.createNonExportableSoftwareKey(tag: tag)
        wasCreated = true
    }

    func isNonExportable() -> Bool {
        Self.isNonExportable(privateKey)
    }

    func publicJWK() throws -> [String: Any] {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw AgentError.invalidPublicKey
        }
        var error: Unmanaged<CFError>?
        guard let external = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?,
              external.count == 65,
              external.first == 0x04 else {
            throw AgentError.invalidPublicKey
        }
        return [
            "kty": "EC",
            "crv": "P-256",
            "x": base64URL(external.subdata(in: 1..<33)),
            "y": base64URL(external.subdata(in: 33..<65)),
            "ext": true,
        ]
    }

    func sign(_ data: Data) throws -> Data {
        var error: Unmanaged<CFError>?
        if let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            data as CFData,
            &error
        ) as Data? {
            return signature
        }
        let signingError = error?.takeRetainedValue()
        if let signingError,
           CFErrorGetCode(signingError) == Int(errSecUserCanceled) {
            throw AgentError.server(
                "Mac approval was canceled. Try again and approve TerminalDBRemoteAgent in the Keychain prompt."
            )
        }
        throw AgentError.cryptography(signingError?.localizedDescription ?? "signature")
    }

    func sharedSecret(peerJWK: [String: Any]) throws -> Data {
        guard let xValue = peerJWK["x"] as? String,
              let yValue = peerJWK["y"] as? String,
              let x = decodeBase64URL(xValue),
              let y = decodeBase64URL(yValue),
              x.count == 32,
              y.count == 32 else {
            throw AgentError.invalidPublicKey
        }
        var representation = Data([0x04])
        representation.append(x)
        representation.append(y)
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 256,
        ]
        var importError: Unmanaged<CFError>?
        guard let peer = SecKeyCreateWithData(
            representation as CFData,
            attributes as CFDictionary,
            &importError
        ) else {
            throw AgentError.invalidPublicKey
        }
        var exchangeError: Unmanaged<CFError>?
        guard let secret = SecKeyCopyKeyExchangeResult(
            privateKey,
            .ecdhKeyExchangeStandard,
            peer,
            [:] as CFDictionary,
            &exchangeError
        ) as Data? else {
            throw AgentError.cryptography(exchangeError?.takeRetainedValue().localizedDescription ?? "ECDH")
        }
        return secret
    }
}

private struct DirectionalKeys {
    let send: SymmetricKey
    let receive: SymmetricKey
}

private func controllerKeyMaterial(
    response: [String: Any],
    pairingSecrets: [String: String]
) throws -> String {
    if let accountKeySalt = response["keySalt"] as? String, !accountKeySalt.isEmpty {
        return accountKeySalt
    }
    if let pairingID = response["pairingId"] as? String,
       let pairingSecret = pairingSecrets[pairingID] {
        return pairingSecret
    }
    throw AgentError.cryptography("The controller key material is no longer available")
}

private func deriveKeys(
    identity: DeviceIdentity,
    peerJWK: [String: Any],
    pairingSecret: String,
    sessionID: String
) throws -> DirectionalKeys {
    let shared = try identity.sharedSecret(peerJWK: peerJWK)
    let expanded = HKDF<SHA256>.deriveKey(
        inputKeyMaterial: SymmetricKey(data: shared),
        salt: Data(pairingSecret.utf8),
        info: Data("TerminalDB Remote v1:\(sessionID)".utf8),
        outputByteCount: 64
    )
    let bytes = expanded.withUnsafeBytes { Data($0) }
    return DirectionalKeys(
        send: SymmetricKey(data: bytes.subdata(in: 0..<32)),
        receive: SymmetricKey(data: bytes.subdata(in: 32..<64))
    )
}

private struct AgentState: Codable {
    var enabled = false
    var baseURL = ""
    var deviceID: String?
    var sessionID: String?
    var generation: Int?
    var accountOwned: Bool?
}

private final class StateStore {
    let directory: URL
    let socketURL: URL
    let secretURL: URL
    let stateURL: URL

    init() throws {
        if let override = ProcessInfo.processInfo.environment["TERMINALDB_REMOTE_STATE_DIR"],
           !override.isEmpty {
            directory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            directory = support.appendingPathComponent("TerminalDB/Remote", isDirectory: true)
        }
        socketURL = directory.appendingPathComponent("agent.sock")
        secretURL = directory.appendingPathComponent("agent.secret")
        stateURL = directory.appendingPathComponent("state.json")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func load() -> AgentState {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(AgentState.self, from: data) else {
            return AgentState()
        }
        return state
    }

    func save(_ state: AgentState) throws {
        let data = try JSONEncoder().encode(state)
        try data.write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }
}

private final class LocalClient {
    let descriptor: Int32
    var readSource: DispatchSourceRead?
    var buffer = Data()
    var authenticated = false
    var instanceID: String?
    weak var agent: RemoteAgent?

    init(descriptor: Int32, agent: RemoteAgent) {
        self.descriptor = descriptor
        self.agent = agent
    }

    func start(on queue: DispatchQueue) {
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { [descriptor] in Darwin.close(descriptor) }
        readSource = source
        source.resume()
    }

    private func readAvailable() {
        var bytes = [UInt8](repeating: 0, count: 16_384)
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        if count <= 0 {
            readSource?.cancel()
            agent?.clientClosed(self)
            return
        }
        buffer.append(bytes, count: count)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let frame = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !frame.isEmpty,
                  let message = try? jsonObject(frame) else { continue }
            agent?.handleLocal(message, from: self)
        }
    }

    func send(_ value: [String: Any]) {
        guard var data = try? jsonData(value) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { pointer in
            guard let address = pointer.baseAddress else { return }
            var remaining = data.count
            var offset = 0
            while remaining > 0 {
                let written = Darwin.write(descriptor, address.advanced(by: offset), remaining)
                if written <= 0 { break }
                remaining -= written
                offset += written
            }
        }
    }
}

private final class CloudSession: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    weak var agent: RemoteAgent?
    var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private let lifecycleLock = NSLock()
    private var open = false
    private var openedOnce = false
    private var terminal = false
    private var connectionTimeout: DispatchWorkItem?
    private var pingOutstanding = false
    private var pingGeneration = 0

    var isOpen: Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return open
    }

    var hasOpened: Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return openedOnce
    }

    init(agent: RemoteAgent) {
        self.agent = agent
    }

    func connect(url: URL) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        task = session?.webSocketTask(with: url)
        task?.resume()
        receiveNext()
        let timeout = DispatchWorkItem { [weak self] in
            self?.connectionTimedOut()
        }
        lifecycleLock.lock()
        connectionTimeout = timeout
        lifecycleLock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + 15,
            execute: timeout
        )
    }

    func close() {
        guard finishLifecycle() else { return }
        disposeTransport()
    }

    func send(_ value: [String: Any]) {
        guard let data = try? jsonData(value),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { [weak self] error in
            if let error, let self {
                self.fail(error.localizedDescription)
            }
        }
    }

    func ping() {
        lifecycleLock.lock()
        guard open, !terminal, !pingOutstanding else {
            lifecycleLock.unlock()
            return
        }
        pingOutstanding = true
        pingGeneration += 1
        let generation = pingGeneration
        lifecycleLock.unlock()

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 45) {
            [weak self] in
            self?.pingTimedOut(generation: generation)
        }
        task?.sendPing { [weak self] error in
            self?.finishPing(generation: generation, error: error)
        }
    }

    private func connectionTimedOut() {
        lifecycleLock.lock()
        let shouldFail = !terminal && !openedOnce
        lifecycleLock.unlock()
        if shouldFail {
            fail("WebSocket authentication timed out. Retrying automatically.")
        }
    }

    private func pingTimedOut(generation: Int) {
        lifecycleLock.lock()
        let shouldFail = !terminal && open && pingOutstanding &&
            pingGeneration == generation
        lifecycleLock.unlock()
        if shouldFail {
            fail("WebSocket health acknowledgement timed out. Retrying automatically.")
        }
    }

    private func finishPing(generation: Int, error: Error?) {
        lifecycleLock.lock()
        guard !terminal, pingOutstanding, pingGeneration == generation else {
            lifecycleLock.unlock()
            return
        }
        pingOutstanding = false
        lifecycleLock.unlock()
        if let error { fail(error.localizedDescription) }
    }

    private func markOpened() -> Bool {
        lifecycleLock.lock()
        guard !terminal else {
            lifecycleLock.unlock()
            return false
        }
        open = true
        openedOnce = true
        let timeout = connectionTimeout
        connectionTimeout = nil
        lifecycleLock.unlock()
        timeout?.cancel()
        return true
    }

    private func finishLifecycle() -> Bool {
        lifecycleLock.lock()
        guard !terminal else {
            lifecycleLock.unlock()
            return false
        }
        terminal = true
        open = false
        pingOutstanding = false
        pingGeneration += 1
        let timeout = connectionTimeout
        connectionTimeout = nil
        lifecycleLock.unlock()
        timeout?.cancel()
        return true
    }

    private func disposeTransport() {
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
    }

    private func fail(_ detail: String) {
        guard finishLifecycle() else { return }
        disposeTransport()
        agent?.cloudFailed(detail, session: self)
    }

    private func receiveNext() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.fail(error.localizedDescription)
            case .success(let message):
                let data: Data?
                switch message {
                case .string(let value): data = Data(value.utf8)
                case .data(let value): data = value
                @unknown default: data = nil
                }
                if let data, let object = try? jsonObject(data) {
                    self.agent?.handleCloud(object)
                }
                self.receiveNext()
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        guard markOpened() else {
            webSocketTask.cancel(with: .normalClosure, reason: nil)
            return
        }
        agent?.cloudOpened(self)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        guard finishLifecycle() else { return }
        agent?.cloudClosed(self)
    }
}

private struct SequencedInputCommand {
    let tabID: String
    let input: String
    let requestID: String
    let sourceID: String
    let expiresAt: Int
    let streamID: String
    let sequence: Int
}

private struct InputStreamLane {
    var nextSequence = 1
    var pending: [Int: SequencedInputCommand] = [:]

    mutating func accept(
        _ command: SequencedInputCommand,
        maximumPending: Int = 256
    ) -> (ready: [SequencedInputCommand], duplicate: Bool, overflow: Bool) {
        if command.sequence < nextSequence {
            return ([], true, false)
        }
        if command.sequence > nextSequence {
            guard pending[command.sequence] == nil else {
                return ([], true, false)
            }
            guard pending.count < maximumPending else {
                return ([], false, true)
            }
            pending[command.sequence] = command
            return ([], false, false)
        }
        var ready = [command]
        nextSequence += 1
        while let next = pending.removeValue(forKey: nextSequence) {
            ready.append(next)
            nextSequence += 1
        }
        return (ready, false, false)
    }
}

private final class RemoteAgent: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.terminaldb.remote-agent")
    private let store: StateStore
    private let identity: DeviceIdentity
    private var state: AgentState
    private var listener: Int32 = -1
    private var listenerSource: DispatchSourceRead?
    private var clients: [Int32: LocalClient] = [:]
    private var inventories: [String: [String: Any]] = [:]
    private var tabOwners: [String: LocalClient] = [:]
    private var launchSecret = ""
    private var cloud: CloudSession?
    private var pairingSecrets: [String: String] = [:]
    private var controllerKeys: [String: DirectionalKeys] = [:]
    private var pendingCloudEnvelopes: [String: [[String: Any]]] = [:]
    private var loadingControllerKeyIDs: Set<String> = []
    private var viewedTabs: [String: String] = [:]
    private var geometryOwners: [String: String] = [:]
    private var sequences: [String: Int] = [:]
    private var receivedSequenceWindows: [String: Set<Int>] = [:]
    private var receivedSequenceHighWater: [String: Int] = [:]
    private var inputStreamLanes: [String: InputStreamLane] = [:]
    private var reconnectAttempt = 0
    private var reconnectWork: DispatchWorkItem?
    private var rotationWork: DispatchWorkItem?
    private var shutdownWork: DispatchWorkItem?
    private var healthTimer: DispatchSourceTimer?
    private var cloudReady = false
    private var endingRemote = false
    private var lastStatus = "disabled"
    private var rotationPreviousCloud: CloudSession?
    private var activePairingURL: String?
    private var activePairingExpiresAt: Int?
    private var trustedControllers: [[String: Any]] = []
    private var accountBootstrapInProgress = false
    private var accountResumeInProgress = false

    private var rotationDelaySeconds: Double {
        let environment = ProcessInfo.processInfo.environment
        guard environment["TERMINALDB_REMOTE_EPHEMERAL_IDENTITY"] == "1",
              let value = environment["TERMINALDB_REMOTE_ROTATION_SECONDS"],
              let seconds = Double(value),
              seconds >= 5 else {
            return 110 * 60
        }
        return seconds
    }

    init() throws {
        store = try StateStore()
        identity = try DeviceIdentity()
        state = store.load()
        if identity.wasCreated && state.deviceID != nil {
            // A missing or legacy exportable key was replaced. Its previous
            // cloud registration can no longer authenticate, so force the
            // next one-click enable through fresh enrollment.
            state.deviceID = nil
            state.sessionID = nil
            state.generation = nil
            state.enabled = false
            try? store.save(state)
        }
        // Pairing secrets are intentionally memory-only. A crashed agent ends the
        // previous session rather than weakening the E2E key exchange.
        if state.enabled {
            state.enabled = false
            try? store.save(state)
        }
    }

    func run() throws {
        try installLocalSocket()
        broadcastStatus(state.enabled ? "connecting" : "disabled")
        let startupShutdown = DispatchWorkItem { [weak self] in
            guard let self,
                  self.clients.values.allSatisfy({ !$0.authenticated }) else {
                return
            }
            exit(0)
        }
        shutdownWork = startupShutdown
        queue.asyncAfter(deadline: .now() + 10, execute: startupShutdown)
        if let orphanedSession = state.sessionID {
            Task {
                _ = try? await request(
                    method: "POST",
                    path: "/api/v1/sessions/\(orphanedSession)/end",
                    body: [:],
                    authenticated: true
                )
                queue.async {
                    if self.state.sessionID == orphanedSession && !self.state.enabled {
                        self.state.sessionID = nil
                        self.state.generation = nil
                        try? self.store.save(self.state)
                        self.resumeAccountRemoteIfReady()
                    }
                }
            }
        }
    }

    private func installLocalSocket() throws {
        unlink(store.socketURL.path)
        listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw AgentError.socket(String(cString: strerror(errno))) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = store.socketURL.path
        let sunPathSize = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8CString.count <= sunPathSize else {
            throw AgentError.socket("path is too long")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: sunPathSize) {
                _ = strlcpy($0, path, sunPathSize)
            }
        }
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else { throw AgentError.socket(String(cString: strerror(errno))) }
        chmod(store.socketURL.path, 0o600)
        guard Darwin.listen(listener, 16) == 0 else {
            throw AgentError.socket(String(cString: strerror(errno)))
        }
        launchSecret = randomURLSafe(byteCount: 32)
        try Data(launchSecret.utf8).write(to: store.secretURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.secretURL.path)
        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        source.setCancelHandler { [listener] in Darwin.close(listener) }
        listenerSource = source
        source.resume()
    }

    private func acceptClient() {
        let descriptor = Darwin.accept(listener, nil, nil)
        guard descriptor >= 0 else { return }
        shutdownWork?.cancel()
        shutdownWork = nil
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(descriptor, &peerUID, &peerGID) == 0,
              peerUID == geteuid() else {
            Darwin.close(descriptor)
            return
        }
        let client = LocalClient(descriptor: descriptor, agent: self)
        clients[descriptor] = client
        client.start(on: queue)
    }

    func clientClosed(_ client: LocalClient) {
        queue.async {
            self.clients.removeValue(forKey: client.descriptor)
            if let instanceID = client.instanceID {
                self.inventories.removeValue(forKey: instanceID)
                self.tabOwners = self.tabOwners.filter { $0.value !== client }
                self.geometryOwners = self.geometryOwners.filter {
                    self.tabOwners[$0.key] != nil
                }
                self.publishInventory()
            }
            if self.clients.values.allSatisfy({ !$0.authenticated }) {
                self.shutdownWork?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self,
                          self.clients.values.allSatisfy({ !$0.authenticated }) else {
                        return
                    }
                    self.disableRemote(notifyServer: true)
                    self.queue.asyncAfter(deadline: .now() + 4) {
                        if self.clients.values.allSatisfy({ !$0.authenticated }) {
                            exit(0)
                        }
                    }
                }
                self.shutdownWork = work
                self.queue.asyncAfter(deadline: .now() + 2, execute: work)
            }
        }
    }

    func handleLocal(_ message: [String: Any], from client: LocalClient) {
        queue.async {
            let type = message["type"] as? String ?? ""
            if !client.authenticated {
                guard type == "hello",
                      message["secret"] as? String == self.launchSecret,
                      let instanceID = message["instanceId"] as? String else {
                    client.send(["type": "error", "message": "Local authentication failed"])
                    client.readSource?.cancel()
                    return
                }
                client.authenticated = true
                client.instanceID = instanceID
                self.shutdownWork?.cancel()
                self.shutdownWork = nil
                client.send(self.statusMessage())
                self.resumeAccountRemoteIfReady()
                return
            }
            switch type {
            case "enable":
                guard let baseURL = message["baseURL"] as? String,
                      let enrollmentCode = message["enrollmentCode"] as? String else {
                    client.send(["type": "error", "message": "Base URL and enrollment code are required"])
                    return
                }
                self.enableRemote(baseURL: baseURL, enrollmentCode: enrollmentCode)
            case "disable":
                self.disableRemote(notifyServer: true)
            case "createPairing":
                self.createPairing()
            case "createAccountBootstrap":
                guard let baseURL = message["baseURL"] as? String else {
                    client.send(["type": "error", "message": "Remote web URL is required"])
                    return
                }
                self.beginAccountBootstrap(baseURL: baseURL)
            case "resetAccountPassword":
                guard let password = message["password"] as? String else {
                    client.send(["type": "error", "message": "A new password is required"])
                    return
                }
                self.resetAccountPassword(password)
            case "deleteAccount":
                self.deleteAccountFromMac()
            case "refreshControllers":
                self.refreshControllers()
            case "revokeController":
                if let controllerID = message["controllerId"] as? String {
                    self.revokeController(controllerID)
                }
            case "inventory":
                self.recordInventory(message, from: client)
            case "output":
                self.publishOutput(message)
            case "ack":
                self.publishAcknowledgement(message)
            case "snapshot":
                self.publishSnapshot(message)
            default:
                break
            }
        }
    }

    private func recordInventory(_ message: [String: Any], from client: LocalClient) {
        guard let instanceID = client.instanceID,
              let instance = message["instance"] as? [String: Any] else { return }
        // A local process republishes its complete authoritative inventory.
        // Remove its old ownership mappings first so closed tabs cannot be
        // targeted through a stale tab ID.
        tabOwners = tabOwners.filter { $0.value !== client }
        inventories[instanceID] = instance
        if let tabs = instance["tabs"] as? [[String: Any]] {
            for tab in tabs {
                if let tabID = tab["id"] as? String { tabOwners[tabID] = client }
            }
        }
        geometryOwners = geometryOwners.filter { tabOwners[$0.key] != nil }
        publishInventory()
    }

    private func inventoryPayload() -> [String: Any] {
        var accountsByID: [String: [String: Any]] = [:]
        for instance in inventories.values {
            for account in instance["accounts"] as? [[String: Any]] ?? [] {
                if let id = account["id"] as? String { accountsByID[id] = account }
            }
        }
        let cleanedInstances = inventories.values.map { instance -> [String: Any] in
            var copy = instance
            copy.removeValue(forKey: "accounts")
            return copy
        }
        var payload: [String: Any] = [
            "instances": cleanedInstances,
            "accounts": Array(accountsByID.values),
            "capabilities": browserCapabilities,
        ]
        if let selectedTabID = viewedTabs.values.first {
            payload["selectedTabId"] = selectedTabID
        }
        return payload
    }

    private func publishInventory() {
        for controllerID in controllerKeys.keys {
            sendEncrypted(route: "inventory", payload: inventoryPayload(), to: controllerID, ttlMilliseconds: 30_000)
        }
    }

    private func viewportGeometry(
        _ payload: [String: Any]
    ) -> (columns: Int, rows: Int)? {
        guard let columns = payload["columns"] as? Int,
              let rows = payload["rows"] as? Int,
              (20...500).contains(columns),
              (5...200).contains(rows) else { return nil }
        return (columns, rows)
    }

    private func sendViewportGeometry(
        tabID: String,
        controllerID: String,
        geometry: (columns: Int, rows: Int)?,
        active: Bool
    ) {
        guard let owner = tabOwners[tabID] else { return }
        owner.send([
            "type": "resize",
            "tabId": tabID,
            "controllerId": controllerID,
            "columns": geometry?.columns ?? 0,
            "rows": geometry?.rows ?? 0,
            "active": active,
        ])
    }

    private func releaseViewportGeometry(
        tabID: String,
        controllerID: String
    ) {
        guard geometryOwners[tabID] == controllerID else { return }
        geometryOwners.removeValue(forKey: tabID)
        sendViewportGeometry(
            tabID: tabID,
            controllerID: controllerID,
            geometry: nil,
            active: false
        )
    }

    private func publishOutput(_ message: [String: Any]) {
        guard let tabID = message["tabId"] as? String,
              let text = message["text"] as? String else { return }
        if message["overflow"] as? Bool == true, let owner = tabOwners[tabID] {
            for (controllerID, viewedTab) in viewedTabs where viewedTab == tabID {
                owner.send([
                    "type": "snapshotRequest",
                    "tabId": tabID,
                    "controllerId": controllerID,
                ])
            }
            return
        }
        for (controllerID, viewedTab) in viewedTabs where viewedTab == tabID {
            var payload: [String: Any] = [
                "tabId": tabID,
                "text": text,
                "rows": message["rows"] as? Int ?? 24,
                "columns": message["columns"] as? Int ?? 80,
                "viewport": false,
                "inputMode": message["inputMode"] as? String ?? "secure",
            ]
            if let inputStreamID = message["inputStreamId"] as? String,
               let inputThrough = message["inputThrough"] as? Int {
                payload["inputStreamId"] = inputStreamID
                payload["inputThrough"] = inputThrough
            }
            sendEncrypted(
                route: "pty.output",
                payload: payload,
                to: controllerID,
                ttlMilliseconds: 10_000
            )
        }
    }

    private func publishSnapshot(_ message: [String: Any]) {
        guard let tabID = message["tabId"] as? String,
              let text = message["text"] as? String else { return }
        let destinations: [String]
        if let controllerID = message["controllerId"] as? String {
            destinations = [controllerID]
        } else {
            destinations = viewedTabs.compactMap { controllerID, viewedTab in
                viewedTab == tabID ? controllerID : nil
            }
        }
        for controllerID in destinations {
            var payload: [String: Any] = [
                "tabId": tabID,
                "text": text,
                "rows": message["rows"] as? Int ?? 24,
                "columns": message["columns"] as? Int ?? 80,
                "viewport": true,
                "inputMode": message["inputMode"] as? String ?? "secure",
            ]
            if let snapshotID = message["snapshotId"] as? String,
               let chunkIndex = message["chunkIndex"] as? Int,
               let chunkCount = message["chunkCount"] as? Int {
                payload["snapshotId"] = snapshotID
                payload["chunkIndex"] = chunkIndex
                payload["chunkCount"] = chunkCount
            }
            if let inputStreamID = message["inputStreamId"] as? String,
               let inputThrough = message["inputThrough"] as? Int {
                payload["inputStreamId"] = inputStreamID
                payload["inputThrough"] = inputThrough
            }
            sendEncrypted(
                route: "viewport.snapshot",
                payload: payload,
                to: controllerID,
                ttlMilliseconds: 30_000
            )
        }
    }

    private func publishAcknowledgement(_ message: [String: Any]) {
        guard let controllerID = message["controllerId"] as? String,
              let requestID = message["requestId"] as? String else { return }
        var payload: [String: Any] = [
            "requestId": requestID,
            "accepted": message["accepted"] as? Bool ?? false,
        ]
        if let detail = message["detail"] as? String { payload["detail"] = detail }
        if let inputStreamID = message["inputStreamId"] as? String,
           let inputThrough = message["inputThrough"] as? Int {
            payload["inputStreamId"] = inputStreamID
            payload["inputThrough"] = inputThrough
        }
        sendEncrypted(route: "ack", payload: payload, to: controllerID, ttlMilliseconds: 15_000)
    }

    private func enableRemote(baseURL: String, enrollmentCode: String) {
        broadcastStatus("connecting")
        Task {
            do {
                let normalized = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                state.baseURL = normalized
                var accountEnrollment = false
                if state.deviceID == nil {
                    let environment = ProcessInfo.processInfo.environment
                    let ephemeralName = environment["TERMINALDB_REMOTE_EPHEMERAL_IDENTITY"] == "1"
                        ? environment["TERMINALDB_REMOTE_DEVICE_NAME"]
                        : nil
                    var enrollmentBody: [String: Any] = [
                        "code": enrollmentCode,
                        "deviceName": ephemeralName ?? Host.current().localizedName ?? "Mac",
                        "signingPublicKey": try identity.publicJWK(),
                        "agreementPublicKey": try identity.publicJWK(),
                    ]
                    if ephemeralName != nil { enrollmentBody["temporary"] = true }
                    let response = try await request(
                        method: "POST",
                        path: "/api/v1/enrollments/redeem",
                        body: enrollmentBody,
                        authenticated: false
                    )
                    state.deviceID = response["deviceId"] as? String
                    accountEnrollment = response["accountOwned"] as? Bool ?? false
                } else {
                    // A Cognito-bound enrollment code upgrades an existing
                    // link-only Mac without rotating its Keychain identity.
                    // Operator enrollment codes are accepted as a no-op.
                    let response = try await request(
                        method: "POST",
                        path: "/api/v1/devices/claim",
                        body: ["code": enrollmentCode],
                        authenticated: true
                    )
                    accountEnrollment = response["claimed"] as? Bool ?? false
                }
                guard state.deviceID != nil else { throw AgentError.notEnrolled }
                let session = try await request(
                    method: "POST",
                    path: "/api/v1/sessions",
                    body: ["protocolVersion": protocolVersion],
                    authenticated: true
                )
                guard let sessionID = session["sessionId"] as? String,
                      let generation = session["generation"] as? Int else {
                    throw AgentError.invalidResponse
                }
                state.sessionID = sessionID
                state.generation = generation
                state.accountOwned = session["accountOwned"] as? Bool ?? accountEnrollment
                state.enabled = true
                try store.save(state)
                try await openCloudSocket()
                if accountEnrollment {
                    queue.async {
                        self.broadcastStatus(
                            "connecting",
                            detail: "This Mac is available in your TerminalDB account."
                        )
                    }
                } else {
                    try await requestPairing(sessionID: sessionID, baseURL: normalized)
                }
            } catch {
                queue.async {
                    let detail = error.localizedDescription
                    self.finishDisablingRemote(notifyServer: true)
                    self.broadcastError(detail)
                }
            }
        }
    }

    private func resetAccountPassword(_ password: String) {
        guard state.deviceID != nil else {
            broadcastError("Connect this Mac to a TerminalDB account first.")
            return
        }
        Task {
            do {
                _ = try await request(
                    method: "POST",
                    path: "/api/v1/device/account/recover",
                    body: ["password": password],
                    authenticated: true
                )
                queue.async {
                    self.broadcastStatus(
                        self.lastStatus,
                        detail: "Password changed. Sign in again with your existing authenticator-app TOTP."
                    )
                }
            } catch {
                queue.async { self.broadcastError(error.localizedDescription) }
            }
        }
    }

    private func deleteAccountFromMac() {
        guard state.deviceID != nil else {
            broadcastError("Connect this Mac to a TerminalDB account first.")
            return
        }
        Task {
            do {
                _ = try await request(
                    method: "DELETE",
                    path: "/api/v1/device/account",
                    body: [:],
                    authenticated: true
                )
                queue.async {
                    self.finishDisablingRemote(notifyServer: false)
                    self.state.deviceID = nil
                    self.state.accountOwned = false
                    try? self.store.save(self.state)
                    self.broadcastStatus(
                        "disabled",
                        detail: "TerminalDB account deleted. One-time links are still available."
                    )
                }
            } catch {
                queue.async { self.broadcastError(error.localizedDescription) }
            }
        }
    }

    private func accountBootstrapProof() throws -> [String: Any] {
        let signingPublicKey = try identity.publicJWK()
        let agreementPublicKey = try identity.publicJWK()
        let timestamp = Int(Date().timeIntervalSince1970 * 1_000)
        let nonce = UUID().uuidString.lowercased()
        let deviceName = Host.current().localizedName ?? "Mac"
        guard let signingX = signingPublicKey["x"] as? String,
              let signingY = signingPublicKey["y"] as? String,
              let agreementX = agreementPublicKey["x"] as? String,
              let agreementY = agreementPublicKey["y"] as? String else {
            throw AgentError.invalidPublicKey
        }
        let canonical = [
            String(timestamp), nonce, deviceName,
            signingX, signingY, agreementX, agreementY,
        ].joined(separator: "\n")
        return [
            "timestamp": timestamp,
            "nonce": nonce,
            "deviceName": deviceName,
            "signingPublicKey": signingPublicKey,
            "agreementPublicKey": agreementPublicKey,
            "signature": base64URL(try identity.sign(Data(canonical.utf8))),
        ]
    }

    private func accountBootstrapURL(baseURL: String, token: String) throws -> String {
        guard var components = URLComponents(string: baseURL) else {
            throw AgentError.server("Invalid TerminalDB Remote URL")
        }
        components.queryItems = [
            URLQueryItem(name: "account", value: "create"),
            URLQueryItem(name: "source", value: "desktop"),
        ]
        components.fragment = "account-bootstrap=\(token)"
        guard let url = components.url else {
            throw AgentError.server("Invalid TerminalDB account URL")
        }
        return url.absoluteString
    }

    private func beginAccountBootstrap(
        baseURL: String,
        controllerID: String? = nil,
        requestID: String? = nil
    ) {
        guard !accountBootstrapInProgress else {
            if let controllerID, let requestID {
                sendEncrypted(
                    route: "ack",
                    payload: [
                        "requestId": requestID,
                        "accepted": false,
                        "detail": "Account setup is already in progress on this Mac.",
                    ],
                    to: controllerID,
                    ttlMilliseconds: 10_000
                )
            }
            return
        }
        let normalized = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let permitsLocalQA = ProcessInfo.processInfo.environment[
            "TERMINALDB_REMOTE_EPHEMERAL_IDENTITY"
        ] == "1"
        guard URL(string: normalized)?.scheme == "https" || permitsLocalQA else {
            broadcastError("Account setup requires an HTTPS Remote web URL.")
            return
        }
        accountBootstrapInProgress = true
        state.baseURL = normalized
        try? store.save(state)
        for client in clients.values where client.authenticated {
            client.send(["type": "accountBootstrapStarting"])
        }
        Task {
            var grantDelivered = false
            do {
                let authenticated = self.queue.sync { self.state.deviceID != nil }
                let response = try await self.request(
                    method: "POST",
                    path: "/api/v1/account-bootstrap",
                    body: authenticated ? [:] : try self.accountBootstrapProof(),
                    authenticated: authenticated
                )
                guard let token = response["bootstrapToken"] as? String,
                      let expiresAt = response["expiresAt"] as? Int else {
                    throw AgentError.invalidResponse
                }
                self.queue.async {
                    if let controllerID, let requestID {
                        self.sendEncrypted(
                            route: "account.bootstrap.ready",
                            payload: ["bootstrapToken": token, "expiresAt": expiresAt],
                            to: controllerID,
                            ttlMilliseconds: 30_000
                        )
                        self.sendEncrypted(
                            route: "ack",
                            payload: ["requestId": requestID, "accepted": true],
                            to: controllerID,
                            ttlMilliseconds: 10_000
                        )
                    } else if let url = try? self.accountBootstrapURL(
                        baseURL: normalized,
                        token: token
                    ) {
                        for client in self.clients.values where client.authenticated {
                            client.send(["type": "accountBootstrap", "url": url])
                        }
                    }
                }
                grantDelivered = true
                try await self.pollAccountBootstrap(token: token, expiresAt: expiresAt)
            } catch {
                self.queue.async {
                    self.accountBootstrapInProgress = false
                    if !grantDelivered, let controllerID, let requestID {
                        self.sendEncrypted(
                            route: "ack",
                            payload: [
                                "requestId": requestID,
                                "accepted": false,
                                "detail": error.localizedDescription,
                            ],
                            to: controllerID,
                            ttlMilliseconds: 10_000
                        )
                    } else {
                        self.broadcastError(error.localizedDescription)
                    }
                }
            }
        }
    }

    private func pollAccountBootstrap(token: String, expiresAt: Int) async throws {
        var attempt = 0
        while Int(Date().timeIntervalSince1970) < expiresAt {
            do {
                let response = try await request(
                    method: "POST",
                    path: "/api/v1/account-bootstrap/status",
                    body: ["bootstrapToken": token],
                    authenticated: false
                )
                if response["status"] as? String == "complete",
                   let deviceID = response["deviceId"] as? String {
                    try await activateBootstrappedAccountDevice(deviceID)
                    queue.async { self.accountBootstrapInProgress = false }
                    return
                }
            } catch {
                // Transient network failures are retried until the one-time
                // approval expires. No account mutation is repeated.
            }
            attempt += 1
            let delaySeconds: UInt64 = attempt < 40 ? 3 : 10
            try await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
        }
        throw AgentError.server("Account setup expired. Start again from TerminalDB.")
    }

    private func activateBootstrappedAccountDevice(_ deviceID: String) async throws {
        let previous = queue.sync { (state.sessionID, state.deviceID) }
        if let previousSession = previous.0, previous.1 == deviceID {
            _ = try? await request(
                method: "POST",
                path: "/api/v1/sessions/\(previousSession)/end",
                body: [:],
                authenticated: true
            )
        }
        queue.sync {
            self.finishDisablingRemote(notifyServer: false)
            self.state.deviceID = deviceID
            self.state.accountOwned = true
            try? self.store.save(self.state)
        }
        let session = try await request(
            method: "POST",
            path: "/api/v1/sessions",
            body: ["protocolVersion": protocolVersion],
            authenticated: true
        )
        guard let sessionID = session["sessionId"] as? String,
              let generation = session["generation"] as? Int else {
            throw AgentError.invalidResponse
        }
        queue.sync {
            self.state.sessionID = sessionID
            self.state.generation = generation
            self.state.enabled = true
            try? self.store.save(self.state)
            self.broadcastStatus(
                "connecting",
                detail: "This Mac is available in your TerminalDB account."
            )
        }
        try await openCloudSocket()
    }

    private func resumeAccountRemoteIfReady() {
        guard !accountResumeInProgress,
              state.accountOwned == true,
              !state.enabled,
              state.sessionID == nil,
              state.deviceID != nil,
              !state.baseURL.isEmpty,
              clients.values.contains(where: { $0.authenticated }) else {
            return
        }
        accountResumeInProgress = true
        broadcastStatus(
            "connecting",
            detail: "Reconnecting this enrolled Mac to your TerminalDB account…"
        )
        Task {
            do {
                let session = try await request(
                    method: "POST",
                    path: "/api/v1/sessions",
                    body: ["protocolVersion": protocolVersion],
                    authenticated: true
                )
                guard let sessionID = session["sessionId"] as? String,
                      let generation = session["generation"] as? Int else {
                    throw AgentError.invalidResponse
                }
                queue.sync {
                    self.state.sessionID = sessionID
                    self.state.generation = generation
                    self.state.enabled = true
                    self.accountResumeInProgress = false
                    try? self.store.save(self.state)
                }
                try await openCloudSocket()
            } catch {
                queue.async {
                    self.accountResumeInProgress = false
                    if self.clearRevokedAccountEnrollmentIfNeeded(error) { return }
                    if self.state.enabled {
                        self.cloudFailed(error.localizedDescription)
                    } else {
                        self.broadcastError(
                            "This enrolled Mac could not reconnect: \(error.localizedDescription)"
                        )
                    }
                }
            }
        }
    }

    @discardableResult
    private func clearRevokedAccountEnrollmentIfNeeded(_ error: Error) -> Bool {
        guard let agentError = error as? AgentError,
              agentError.revokesAccountEnrollment,
              state.accountOwned == true else {
            return false
        }
        finishDisablingRemote(notifyServer: false)
        state.deviceID = nil
        state.accountOwned = false
        accountResumeInProgress = false
        try? store.save(state)
        broadcastStatus(
            "disabled",
            detail: "This Mac's TerminalDB account was deleted or its access was revoked. One-time links are still available."
        )
        return true
    }

    private func createPairing() {
        guard state.enabled,
              let sessionID = state.sessionID,
              !state.baseURL.isEmpty else {
            broadcastError("Enable Remote Control before creating a pairing link.")
            return
        }
        let baseURL = state.baseURL
        Task {
            do {
                try await requestPairing(sessionID: sessionID, baseURL: baseURL)
            } catch {
                queue.async {
                    self.broadcastError("Pairing link creation failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func requestPairing(sessionID: String, baseURL: String) async throws {
        let pairing = try await request(
            method: "POST",
            path: "/api/v1/pairings",
            body: ["sessionId": sessionID],
            authenticated: true
        )
        guard let pairingID = pairing["pairingId"] as? String,
              let pairingPath = pairing["pairingPath"] as? String,
              let hashIndex = pairingPath.firstIndex(of: "#") else {
            throw AgentError.invalidResponse
        }
        let secret = String(pairingPath[pairingPath.index(after: hashIndex)...])
        let expiresAt = pairing["expiresAt"] as? Int
        let installed = queue.sync { () -> Bool in
            guard state.enabled, state.sessionID == sessionID else { return false }
            pairingSecrets[pairingID] = secret
            activePairingURL = baseURL + pairingPath
            activePairingExpiresAt = expiresAt
            broadcastStatus(
                cloudReady ? "live" : "connecting",
                pairingURL: activePairingURL,
                expiresAt: activePairingExpiresAt
            )
            return true
        }
        guard installed else { throw AgentError.sessionUnavailable }
    }

    private func disableRemote(notifyServer: Bool) {
        guard state.enabled || state.sessionID != nil else {
            broadcastStatus("disabled")
            return
        }
        guard !endingRemote else { return }
        let connectedControllers = cloudReady ? Array(controllerKeys.keys) : []
        if !connectedControllers.isEmpty {
            endingRemote = true
            for controllerID in connectedControllers {
                sendEncrypted(
                    route: "session.ended",
                    payload: ["reason": "remote-disabled"],
                    to: controllerID,
                    ttlMilliseconds: 10_000
                )
            }
            queue.asyncAfter(deadline: .now() + 0.75) {
                self.finishDisablingRemote(notifyServer: notifyServer)
            }
            return
        }
        finishDisablingRemote(notifyServer: notifyServer)
    }

    private func finishDisablingRemote(notifyServer: Bool) {
        let sessionID = state.sessionID
        endingRemote = false
        state.enabled = false
        for (tabID, controllerID) in geometryOwners {
            sendViewportGeometry(
                tabID: tabID,
                controllerID: controllerID,
                geometry: nil,
                active: false
            )
        }
        geometryOwners.removeAll()
        pairingSecrets.removeAll()
        controllerKeys.removeAll()
        pendingCloudEnvelopes.removeAll()
        loadingControllerKeyIDs.removeAll()
        trustedControllers.removeAll()
        viewedTabs.removeAll()
        sequences.removeAll()
        receivedSequenceWindows.removeAll()
        receivedSequenceHighWater.removeAll()
        inputStreamLanes.removeAll()
        activePairingURL = nil
        activePairingExpiresAt = nil
        cloudReady = false
        reconnectWork?.cancel()
        rotationWork?.cancel()
        healthTimer?.cancel()
        healthTimer = nil
        rotationPreviousCloud?.close()
        rotationPreviousCloud = nil
        cloud?.close()
        cloud = nil
        if notifyServer, let sessionID {
            Task {
                _ = try? await request(
                    method: "POST",
                    path: "/api/v1/sessions/\(sessionID)/end",
                    body: [:],
                    authenticated: true
                )
            }
        }
        state.sessionID = nil
        state.generation = nil
        try? store.save(state)
        broadcastStatus("disabled")
    }

    private func openCloudSocket() async throws {
        guard let sessionID = state.sessionID,
              let deviceID = state.deviceID else { throw AgentError.sessionUnavailable }
        let ticket = try await request(
            method: "POST",
            path: "/api/v1/tickets",
            body: ["sessionId": sessionID, "role": "mac", "clientId": deviceID],
            authenticated: true
        )
        guard let ticketValue = ticket["ticket"] as? String,
              let urlValue = ticket["websocketUrl"] as? String,
              var components = URLComponents(string: urlValue) else {
            throw AgentError.invalidResponse
        }
        components.queryItems = [URLQueryItem(name: "ticket", value: ticketValue)]
        guard let url = components.url else { throw AgentError.invalidResponse }
        await MainActor.run {
            let next = CloudSession(agent: self)
            self.cloud = next
            next.connect(url: url)
        }
    }

    func cloudOpened(_ session: CloudSession) {
        queue.async {
            guard self.cloud === session, self.state.enabled else { return }
            let previous = self.rotationPreviousCloud
            self.rotationPreviousCloud = nil
            self.cloudReady = true
            self.reconnectAttempt = 0
            self.broadcastStatus(
                "live",
                pairingURL: self.activePairingURL,
                expiresAt: self.activePairingExpiresAt
            )
            self.publishInventory()
            self.startHealthTimer()
            self.scheduleRotation()
            self.refreshControllers()
            if let previous, previous !== session {
                self.queue.asyncAfter(deadline: .now() + 30) {
                    previous.close()
                }
            }
        }
    }

    func cloudClosed(_ session: CloudSession) {
        queue.async {
            guard self.cloud === session, self.state.enabled else { return }
            if self.restorePreviousCloudIfPossible(failed: session) { return }
            self.rotationPreviousCloud?.close()
            self.rotationPreviousCloud = nil
            self.cloudReady = false
            self.healthTimer?.cancel()
            self.healthTimer = nil
            self.broadcastStatus("reconnecting")
            self.scheduleReconnect()
        }
    }

    func cloudFailed(_ detail: String, session: CloudSession? = nil) {
        queue.async {
            if let session, self.cloud !== session { return }
            guard self.state.enabled else { return }
            if let session,
               self.restorePreviousCloudIfPossible(failed: session) {
                return
            }
            self.rotationPreviousCloud?.close()
            self.rotationPreviousCloud = nil
            self.cloudReady = false
            self.healthTimer?.cancel()
            self.healthTimer = nil
            self.broadcastStatus("reconnecting", detail: detail)
            self.scheduleReconnect()
        }
    }

    private func restorePreviousCloudIfPossible(failed session: CloudSession) -> Bool {
        guard cloud === session,
              !session.hasOpened,
              let previous = rotationPreviousCloud,
              previous.isOpen else {
            return false
        }
        rotationPreviousCloud = nil
        session.close()
        cloud = previous
        cloudReady = true
        broadcastStatus(
            "live",
            detail: "The replacement connection failed; the existing connection remains live."
        )
        publishInventory()
        startHealthTimer()
        scheduleRotation()
        return true
    }

    private func startHealthTimer() {
        healthTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 20, repeating: 20, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in
            guard let self, self.state.enabled else { return }
            self.cloud?.ping()
            let now = Int(Date().timeIntervalSince1970 * 1_000)
            for controllerID in self.controllerKeys.keys {
                self.sendEncrypted(
                    route: "health.pong",
                    payload: ["sentAt": now, "proactive": true],
                    to: controllerID,
                    ttlMilliseconds: 20_000
                )
            }
        }
        healthTimer = timer
        timer.resume()
    }

    private func scheduleReconnect() {
        guard reconnectWork == nil, state.enabled else { return }
        let delays = [0.5, 1, 2, 4, 8, 15, 30]
        let base = delays[min(reconnectAttempt, delays.count - 1)]
        reconnectAttempt += 1
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWork = nil
            Task {
                do { try await self.openCloudSocket() }
                catch {
                    self.queue.async {
                        if self.clearRevokedAccountEnrollmentIfNeeded(error) { return }
                        self.cloudFailed(error.localizedDescription)
                    }
                }
            }
        }
        reconnectWork = work
        queue.asyncAfter(deadline: .now() + Double.random(in: 0...base), execute: work)
    }

    private func scheduleRotation() {
        rotationWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state.enabled else { return }
            self.broadcastStatus("rotating")
            let previous = self.cloud
            self.rotationPreviousCloud = previous
            Task {
                do {
                    try await self.openCloudSocket()
                } catch {
                    self.queue.async {
                        if self.clearRevokedAccountEnrollmentIfNeeded(error) { return }
                        if self.cloud === previous,
                           previous?.isOpen == true {
                            self.rotationPreviousCloud = nil
                            self.cloudReady = true
                            self.broadcastStatus(
                                "live",
                                detail: "Connection rotation will retry without interrupting the current socket."
                            )
                            self.scheduleRotation()
                        } else {
                            self.cloudFailed(error.localizedDescription)
                        }
                    }
                }
            }
        }
        rotationWork = work
        queue.asyncAfter(deadline: .now() + rotationDelaySeconds, execute: work)
    }

    func handleCloud(_ envelope: [String: Any]) {
        queue.async {
            let now = Int(Date().timeIntervalSince1970 * 1_000)
            guard envelope["version"] as? Int == protocolVersion,
                  envelope["sessionId"] as? String == self.state.sessionID,
                  envelope["generation"] as? Int == self.state.generation,
                  let sourceID = envelope["sourceId"] as? String,
                  let route = envelope["route"] as? String,
                  let sequence = envelope["sequence"] as? Int,
                  let expiresAt = envelope["expiresAt"] as? Int,
                  expiresAt >= now - 1_000,
                  expiresAt <= now + 60_000 else { return }
            var received = self.receivedSequenceWindows[sourceID] ?? []
            guard !received.contains(sequence) else { return }
            received.insert(sequence)
            let highWater = max(
                self.receivedSequenceHighWater[sourceID] ?? 0,
                sequence
            )
            self.receivedSequenceHighWater[sourceID] = highWater
            if received.count > 1_024 {
                let floor = max(0, highWater - 512)
                received = Set(received.filter { $0 >= floor })
            }
            self.receivedSequenceWindows[sourceID] = received
            if let keys = self.controllerKeys[sourceID] {
                self.processCloudEnvelope(
                    envelope,
                    route: route,
                    sourceID: sourceID,
                    expiresAt: expiresAt,
                    keys: keys
                )
                return
            }
            var pending = self.pendingCloudEnvelopes[sourceID] ?? []
            guard pending.count < 256 else { return }
            pending.append(envelope)
            self.pendingCloudEnvelopes[sourceID] = pending
            guard self.loadingControllerKeyIDs.insert(sourceID).inserted else { return }
            Task {
                do {
                    let keys = try await self.controllerKeys(for: sourceID)
                    self.queue.async {
                        self.loadingControllerKeyIDs.remove(sourceID)
                        let queued = self.pendingCloudEnvelopes.removeValue(
                            forKey: sourceID
                        ) ?? []
                        for queuedEnvelope in queued {
                            guard let queuedRoute = queuedEnvelope["route"] as? String,
                                  let queuedExpiry = queuedEnvelope["expiresAt"] as? Int else {
                                continue
                            }
                            self.processCloudEnvelope(
                                queuedEnvelope,
                                route: queuedRoute,
                                sourceID: sourceID,
                                expiresAt: queuedExpiry,
                                keys: keys
                            )
                        }
                    }
                } catch {
                    self.queue.async {
                        self.loadingControllerKeyIDs.remove(sourceID)
                        self.pendingCloudEnvelopes.removeValue(forKey: sourceID)
                        self.broadcastError(error.localizedDescription)
                    }
                }
            }
        }
    }

    private func processCloudEnvelope(
        _ envelope: [String: Any],
        route: String,
        sourceID: String,
        expiresAt: Int,
        keys: DirectionalKeys
    ) {
        guard expiresAt >= Int(Date().timeIntervalSince1970 * 1_000) - 1_000 else {
            return
        }
        do {
            let payload = try decrypt(envelope, keys: keys)
            handleRemoteRoute(
                route,
                payload: payload,
                sourceID: sourceID,
                requestID: envelope["requestId"] as? String ?? "",
                expiresAt: expiresAt
            )
        } catch {
            broadcastError(error.localizedDescription)
        }
    }

    private func handleRemoteRoute(
        _ route: String,
        payload: [String: Any],
        sourceID: String,
        requestID: String,
        expiresAt: Int
    ) {
        switch route {
        case "health.ping":
            sendEncrypted(
                route: "health.pong",
                payload: [
                    "sentAt": payload["sentAt"] as? Int ??
                        Int(Date().timeIntervalSince1970 * 1_000),
                    "proactive": false,
                ],
                to: sourceID,
                ttlMilliseconds: 20_000
            )
        case "presence":
            let previousTabID = viewedTabs[sourceID]
            if payload["visible"] as? Bool == true,
               let tabID = payload["tabId"] as? String {
                if let previousTabID, previousTabID != tabID {
                    releaseViewportGeometry(
                        tabID: previousTabID,
                        controllerID: sourceID
                    )
                }
                viewedTabs[sourceID] = tabID
                if let geometry = viewportGeometry(payload), tabOwners[tabID] != nil {
                    geometryOwners[tabID] = sourceID
                    sendViewportGeometry(
                        tabID: tabID,
                        controllerID: sourceID,
                        geometry: geometry,
                        active: true
                    )
                }
            } else {
                viewedTabs.removeValue(forKey: sourceID)
                if let previousTabID {
                    releaseViewportGeometry(
                        tabID: previousTabID,
                        controllerID: sourceID
                    )
                }
            }
        case "resync.request":
            publishInventory()
            let tabID = payload["tabId"] as? String ?? viewedTabs[sourceID]
            if let tabID, let owner = tabOwners[tabID] {
                viewedTabs[sourceID] = tabID
                if let geometry = viewportGeometry(payload) {
                    geometryOwners[tabID] = sourceID
                    sendViewportGeometry(
                        tabID: tabID,
                        controllerID: sourceID,
                        geometry: geometry,
                        active: true
                    )
                } else {
                    owner.send(["type": "snapshotRequest", "tabId": tabID, "controllerId": sourceID])
                }
            }
            for request in payload["requests"] as? [[String: Any]] ?? [] {
                guard let uncertainID = request["requestId"] as? String,
                      !uncertainID.isEmpty else {
                    continue
                }
                let requestTabID = request["tabId"] as? String
                let owner = requestTabID.flatMap { tabOwners[$0] } ??
                    clients.values.first(where: { $0.authenticated })
                if let owner {
                    owner.send([
                        "type": "ackStatusRequest",
                        "requestId": uncertainID,
                        "controllerId": sourceID,
                    ])
                } else {
                    sendEncrypted(
                        route: "ack",
                        payload: [
                            "requestId": uncertainID,
                            "accepted": false,
                            "detail": "The Mac has no record of accepting this request.",
                        ],
                        to: sourceID,
                        ttlMilliseconds: 10_000
                    )
                }
            }
        case "pty.resize":
            guard let tabID = payload["tabId"] as? String,
                  viewedTabs[sourceID] == tabID,
                  tabOwners[tabID] != nil else { return }
            if payload["active"] as? Bool == false {
                releaseViewportGeometry(tabID: tabID, controllerID: sourceID)
            } else if let geometry = viewportGeometry(payload) {
                geometryOwners[tabID] = sourceID
                sendViewportGeometry(
                    tabID: tabID,
                    controllerID: sourceID,
                    geometry: geometry,
                    active: true
                )
            }
        case "pty.input":
            guard let tabID = payload["tabId"] as? String else {
                sendEncrypted(
                    route: "ack",
                    payload: ["requestId": requestID, "accepted": false, "detail": "Tab is no longer open"],
                    to: sourceID,
                    ttlMilliseconds: 10_000
                )
                return
            }
            if let streamID = payload["inputStreamId"] as? String,
               !streamID.isEmpty,
               streamID.count <= 128,
               let sequence = payload["inputSequence"] as? Int,
               sequence > 0 {
                enqueueSequencedInput(SequencedInputCommand(
                    tabID: tabID,
                    input: payload["input"] as? String ?? "",
                    requestID: requestID,
                    sourceID: sourceID,
                    expiresAt: expiresAt,
                    streamID: streamID,
                    sequence: sequence
                ))
                return
            }
            forwardInput(SequencedInputCommand(
                tabID: tabID,
                input: payload["input"] as? String ?? "",
                requestID: requestID,
                sourceID: sourceID,
                expiresAt: expiresAt,
                streamID: "",
                sequence: 0
            ))
        case "tab.create", "tab.select", "tab.close", "account.switch", "usage.refresh":
            let tabID = payload["tabId"] as? String
            let owner = tabID.flatMap { tabOwners[$0] } ??
                clients.values.first(where: { $0.authenticated })
            guard let owner,
                  route == "usage.refresh" || tabID != nil else {
                sendEncrypted(
                    route: "ack",
                    payload: ["requestId": requestID, "accepted": false, "detail": "Tab is no longer open"],
                    to: sourceID,
                    ttlMilliseconds: 10_000
                )
                return
            }
            owner.send([
                "type": "remoteCommand",
                "route": route,
                "tabId": tabID ?? "",
                "input": payload["input"] as? String ?? "",
                "accountId": payload["accountId"] as? String ?? "",
                "requestId": requestID,
                "controllerId": sourceID,
                "generation": state.generation ?? 0,
                "expiresAt": expiresAt,
            ])
        case "account.bootstrap":
            beginAccountBootstrap(
                baseURL: state.baseURL,
                controllerID: sourceID,
                requestID: requestID
            )
        case "session.end":
            sendEncrypted(
                route: "ack",
                payload: ["requestId": requestID, "accepted": true],
                to: sourceID,
                ttlMilliseconds: 10_000
            )
            queue.asyncAfter(deadline: .now() + 1) {
                self.disableRemote(notifyServer: true)
            }
        default:
            break
        }
    }

    private func inputStreamKey(_ command: SequencedInputCommand) -> String {
        "\(command.sourceID)\u{0}\(command.tabID)\u{0}\(command.streamID)"
    }

    private func enqueueSequencedInput(_ command: SequencedInputCommand) {
        let key = inputStreamKey(command)
        if inputStreamLanes[key] == nil && inputStreamLanes.count >= 512,
           let evictionCandidate = inputStreamLanes.keys.first {
            inputStreamLanes.removeValue(forKey: evictionCandidate)
        }
        var lane = inputStreamLanes[key] ?? InputStreamLane()
        let accepted = lane.accept(command)
        inputStreamLanes[key] = lane
        if accepted.duplicate {
            let alreadyAccepted = command.sequence < lane.nextSequence
            var acknowledgement: [String: Any] = [
                "requestId": command.requestID,
                "accepted": alreadyAccepted,
                "inputStreamId": command.streamID,
                "inputThrough": lane.nextSequence - 1,
            ]
            if !alreadyAccepted {
                acknowledgement["detail"] = "Duplicate pending input sequence"
            }
            sendEncrypted(
                route: "ack",
                payload: acknowledgement,
                to: command.sourceID,
                ttlMilliseconds: 10_000
            )
            return
        }
        if accepted.overflow {
            sendEncrypted(
                route: "ack",
                payload: [
                    "requestId": command.requestID,
                    "accepted": false,
                    "detail": "Input reorder buffer is full",
                    "inputStreamId": command.streamID,
                    "inputThrough": lane.nextSequence - 1,
                ],
                to: command.sourceID,
                ttlMilliseconds: 10_000
            )
            return
        }
        for ready in accepted.ready { forwardInput(ready) }
    }

    private func forwardInput(_ command: SequencedInputCommand) {
        guard let owner = tabOwners[command.tabID] else {
            var failure: [String: Any] = [
                "requestId": command.requestID,
                "accepted": false,
                "detail": "Tab is no longer open",
            ]
            if !command.streamID.isEmpty {
                failure["inputStreamId"] = command.streamID
                failure["inputThrough"] = max(0, command.sequence - 1)
            }
            sendEncrypted(
                route: "ack",
                payload: failure,
                to: command.sourceID,
                ttlMilliseconds: 10_000
            )
            return
        }
        owner.send([
            "type": "remoteCommand",
            "route": "pty.input",
            "tabId": command.tabID,
            "input": command.input,
            "requestId": command.requestID,
            "controllerId": command.sourceID,
            "generation": state.generation ?? 0,
            "expiresAt": command.expiresAt,
            "inputStreamId": command.streamID,
            "inputSequence": command.sequence,
        ])
    }

    private func controllerKeys(for controllerID: String) async throws -> DirectionalKeys {
        if let keys = queue.sync(execute: { controllerKeys[controllerID] }) { return keys }
        guard let sessionID = state.sessionID else { throw AgentError.sessionUnavailable }
        let encodedSession = sessionID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionID
        let encodedController = controllerID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? controllerID
        let response = try await request(
            method: "GET",
            path: "/api/v1/sessions/\(encodedSession)/controllers/\(encodedController)",
            body: nil,
            authenticated: true
        )
        guard let publicKey = response["agreementPublicKey"] as? [String: Any] else {
            throw AgentError.cryptography("The controller public key is unavailable")
        }
        let secrets = queue.sync(execute: { pairingSecrets })
        let keyMaterial = try controllerKeyMaterial(
            response: response,
            pairingSecrets: secrets
        )
        let keys = try deriveKeys(
            identity: identity,
            peerJWK: publicKey,
            pairingSecret: keyMaterial,
            sessionID: sessionID
        )
        queue.sync {
            controllerKeys[controllerID] = keys
            refreshControllers()
        }
        return keys
    }

    private func refreshControllers() {
        guard state.enabled, let sessionID = state.sessionID else {
            trustedControllers.removeAll()
            return
        }
        let encodedSession =
            sessionID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ??
            sessionID
        Task {
            do {
                let response = try await request(
                    method: "GET",
                    path: "/api/v1/sessions/\(encodedSession)/controllers",
                    body: nil,
                    authenticated: true
                )
                let controllers = response["controllers"] as? [[String: Any]] ?? []
                queue.async {
                    guard self.state.sessionID == sessionID else { return }
                    self.trustedControllers = controllers
                    self.broadcastStatus(self.lastStatus)
                }
            } catch {
                // Controller management is diagnostic and must not interrupt the relay.
            }
        }
    }

    private func revokeController(_ controllerID: String) {
        guard state.enabled,
              trustedControllers.contains(where: {
                  $0["controllerId"] as? String == controllerID
              }) else {
            return
        }
        if cloudReady, controllerKeys[controllerID] != nil {
            sendEncrypted(
                route: "session.ended",
                payload: ["reason": "controller-revoked"],
                to: controllerID,
                ttlMilliseconds: 10_000
            )
        }
        let encoded =
            controllerID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ??
            controllerID
        queue.asyncAfter(deadline: .now() + 0.5) {
            Task {
                do {
                    _ = try await self.request(
                        method: "POST",
                        path: "/api/v1/controllers/\(encoded)/revoke",
                        body: [:],
                        authenticated: true
                    )
                    self.queue.async {
                        if let tabID = self.viewedTabs[controllerID] {
                            self.releaseViewportGeometry(
                                tabID: tabID,
                                controllerID: controllerID
                            )
                        }
                        self.controllerKeys.removeValue(forKey: controllerID)
                        self.pendingCloudEnvelopes.removeValue(forKey: controllerID)
                        self.loadingControllerKeyIDs.remove(controllerID)
                        self.viewedTabs.removeValue(forKey: controllerID)
                        self.refreshControllers()
                    }
                } catch {
                    self.queue.async {
                        self.broadcastError("Controller revocation failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func decrypt(
        _ envelope: [String: Any],
        keys: DirectionalKeys
    ) throws -> [String: Any] {
        guard let nonceValue = envelope["nonce"] as? String,
              let ciphertextValue = envelope["ciphertext"] as? String,
              let nonceData = decodeBase64URL(nonceValue),
              let combinedCiphertext = decodeBase64URL(ciphertextValue),
              combinedCiphertext.count >= 16 else {
            throw AgentError.cryptography("Invalid encrypted envelope")
        }
        var metadata = envelope
        metadata.removeValue(forKey: "nonce")
        metadata.removeValue(forKey: "ciphertext")
        let authenticated = try jsonData(metadata)
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let ciphertext = combinedCiphertext.dropLast(16)
        let tag = combinedCiphertext.suffix(16)
        let box = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: ciphertext,
            tag: tag
        )
        let plain = try AES.GCM.open(box, using: keys.receive, authenticating: authenticated)
        let decoded = envelope["compression"] as? String == "deflate"
            ? try inflateBounded(plain)
            : plain
        return try jsonObject(decoded)
    }

    private func sendEncrypted(
        route: String,
        payload: [String: Any],
        to controllerID: String,
        ttlMilliseconds: Int
    ) {
        guard let sessionID = state.sessionID,
              let generation = state.generation,
              let deviceID = state.deviceID else { return }
        guard let keys = controllerKeys[controllerID] else {
            Task {
                do {
                    _ = try await controllerKeys(for: controllerID)
                    queue.async {
                        self.sendEncrypted(
                            route: route,
                            payload: payload,
                            to: controllerID,
                            ttlMilliseconds: ttlMilliseconds
                        )
                    }
                } catch {
                    queue.async { self.broadcastError(error.localizedDescription) }
                }
            }
            return
        }
        do {
            let now = Int(Date().timeIntervalSince1970 * 1_000)
            let sequence = (sequences[controllerID] ?? 0) + 1
            sequences[controllerID] = sequence
            let prepared = deflateIfHelpful(try jsonData(payload))
            let metadata: [String: Any] = [
                "version": protocolVersion,
                "route": route,
                "sessionId": sessionID,
                "sourceId": deviceID,
                "destinationId": controllerID,
                "generation": generation,
                "sequence": sequence,
                "requestId": randomURLSafe(byteCount: 18),
                "sentAt": now,
                "expiresAt": now + ttlMilliseconds,
                "compression": prepared.marker,
            ]
            let authenticated = try jsonData(metadata)
            let sealed = try AES.GCM.seal(
                prepared.data,
                using: keys.send,
                authenticating: authenticated
            )
            guard let nonce = sealed.nonce.withUnsafeBytes({ Data($0) }) as Data?,
                  let tag = sealed.tag as Data? else {
                throw AgentError.cryptography("AES-GCM did not produce a complete envelope")
            }
            var cipher = sealed.ciphertext
            cipher.append(tag)
            var envelope = metadata
            envelope["nonce"] = base64URL(nonce)
            envelope["ciphertext"] = base64URL(cipher)
            let wire = try jsonData(envelope)
            guard wire.count <= maximumWireBytes else {
                throw AgentError.cryptography("Encrypted message exceeds 30 KB")
            }
            cloud?.send(envelope)
        } catch {
            broadcastError(error.localizedDescription)
        }
    }

    private func request(
        method: String,
        path: String,
        body: [String: Any]?,
        authenticated: Bool
    ) async throws -> [String: Any] {
        guard let base = URL(string: state.baseURL),
              let url = URL(string: path, relativeTo: base)?.absoluteURL else {
            throw AgentError.server("Invalid TerminalDB Remote URL")
        }
        let bodyData = try body.map(jsonData) ?? Data()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body == nil ? nil : bodyData
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "content-type") }
        if authenticated {
            guard let principal = state.deviceID else { throw AgentError.notEnrolled }
            let timestamp = String(Int(Date().timeIntervalSince1970 * 1_000))
            let nonce = UUID().uuidString.lowercased()
            let bodyString = String(data: bodyData, encoding: .utf8) ?? ""
            let canonical = [method.uppercased(), path, timestamp, nonce, sha256URL(bodyString)]
                .joined(separator: "\n")
            request.setValue(principal, forHTTPHeaderField: "x-terminaldb-principal")
            request.setValue(timestamp, forHTTPHeaderField: "x-terminaldb-timestamp")
            request.setValue(nonce, forHTTPHeaderField: "x-terminaldb-nonce")
            request.setValue(
                base64URL(try identity.sign(Data(canonical.utf8))),
                forHTTPHeaderField: "x-terminaldb-signature"
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AgentError.invalidResponse }
        let parsed = (try? jsonObject(data)) ?? [:]
        guard (200..<300).contains(http.statusCode) else {
            throw AgentError.remoteHTTP(
                statusCode: http.statusCode,
                code: parsed["code"] as? String,
                message: parsed["error"] as? String ??
                    "Remote service returned HTTP \(http.statusCode)"
            )
        }
        return parsed
    }

    private func statusMessage(
        _ status: String? = nil,
        pairingURL: String? = nil,
        expiresAt: Int? = nil,
        detail: String? = nil
    ) -> [String: Any] {
        var message: [String: Any] = [
            "type": "remoteStatus",
            "state": status ?? lastStatus,
            "enabled": state.enabled,
            "accountOwned": state.accountOwned == true,
            "capabilities": localAgentCapabilities,
            "controllers": trustedControllers,
        ]
        if let pairingURL { message["pairingURL"] = pairingURL }
        else if let activePairingURL { message["pairingURL"] = activePairingURL }
        if let expiresAt { message["expiresAt"] = expiresAt }
        else if let activePairingExpiresAt { message["expiresAt"] = activePairingExpiresAt }
        if let detail { message["detail"] = detail }
        return message
    }

    private func broadcastStatus(
        _ status: String,
        pairingURL: String? = nil,
        expiresAt: Int? = nil,
        detail: String? = nil
    ) {
        lastStatus = status
        let message = statusMessage(status, pairingURL: pairingURL, expiresAt: expiresAt, detail: detail)
        for client in clients.values where client.authenticated { client.send(message) }
    }

    private func broadcastError(_ detail: String) {
        lastStatus = "error"
        for client in clients.values where client.authenticated {
            client.send(["type": "error", "message": detail])
        }
    }
}

@main
private struct TerminalDBRemoteAgentMain {
    static func main() {
        do {
            if let childIndex = CommandLine.arguments.firstIndex(
                of: "--persistent-identity-child-test"
            ) {
                guard CommandLine.arguments.indices.contains(childIndex + 1),
                      let tag = Data(
                        base64Encoded: CommandLine.arguments[childIndex + 1]
                      ) else {
                    throw AgentError.keyCreation("missing child-test application tag")
                }
                let identity = try DeviceIdentity(applicationTag: tag)
                guard !identity.wasCreated, identity.isNonExportable() else {
                    throw AgentError.keyCreation(
                        "the child process did not reload the persistent key"
                    )
                }
                _ = try identity.sign(Data("TerminalDB child identity QA".utf8))
                return
            }
            if CommandLine.arguments.contains("--persistent-identity-self-test") {
                let tag = Data(
                    "com.terminaldb.remote.qa.\(UUID().uuidString.lowercased())".utf8
                )
                DeviceIdentity.delete(applicationTag: tag)
                defer { DeviceIdentity.delete(applicationTag: tag) }
                let created = try DeviceIdentity(applicationTag: tag)
                let createdPublic = try created.publicJWK()
                guard created.wasCreated, created.isNonExportable() else {
                    throw AgentError.keyCreation("persistent private key was exportable")
                }
                let reloaded = try DeviceIdentity(applicationTag: tag)
                guard NSDictionary(dictionary: createdPublic)
                    .isEqual(to: try reloaded.publicJWK()),
                      !reloaded.wasCreated,
                      reloaded.isNonExportable() else {
                    throw AgentError.keyCreation("persistent private key did not reload")
                }
                _ = try reloaded.sign(Data("TerminalDB persistent identity QA".utf8))
                let child = Process()
                child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
                child.arguments = [
                    "--persistent-identity-child-test",
                    tag.base64EncodedString(),
                ]
                child.standardInput = FileHandle.nullDevice
                child.standardOutput = FileHandle.nullDevice
                child.standardError = FileHandle.nullDevice
                try child.run()
                let childDeadline = Date().addingTimeInterval(5)
                while child.isRunning && Date() < childDeadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if child.isRunning {
                    child.terminate()
                    throw AgentError.keyCreation(
                        "persistent key access blocked after the agent restarted"
                    )
                }
                guard child.terminationStatus == 0 else {
                    throw AgentError.keyCreation(
                        "the restarted agent could not use its persistent key"
                    )
                }
                print("TerminalDB persistent Keychain identity QA: passed")
                return
            }
            if CommandLine.arguments.contains("--self-test") {
                guard browserCapabilities.contains(accountBootstrapCapability),
                      localAgentCapabilities.contains(accountBootstrapCapability) else {
                    throw AgentError.server(
                        "Account bootstrap capability was not advertised"
                    )
                }
                guard AgentError.remoteHTTP(
                    statusCode: 401,
                    code: "PRINCIPAL_REVOKED",
                    message: "revoked"
                ).revokesAccountEnrollment,
                !AgentError.remoteHTTP(
                    statusCode: 401,
                    code: nil,
                    message: "signature failed"
                ).revokesAccountEnrollment else {
                    throw AgentError.server(
                        "Revoked account enrollment classification failed"
                    )
                }
                let expected = Data(
                    String(repeating: "TerminalDB compression vector ", count: 40).utf8
                )
                guard let browserVector = Data(
                    base64Encoded:
                        "C0ktys3MS8xxcVJIzs8tKEotLs7Mz1MoS00uyS9SGJUdlR2VHZUdPLIA"
                ),
                try inflateBounded(browserVector) == expected else {
                    throw AgentError.cryptography(
                        "Browser-to-native DEFLATE compatibility failed"
                    )
                }
                let native = deflateIfHelpful(expected)
                guard native.marker == "deflate",
                      try inflateBounded(native.data) == expected else {
                    throw AgentError.cryptography(
                        "Native DEFLATE round trip failed"
                    )
                }
                guard try controllerKeyMaterial(
                    response: [
                        "keySalt": "account-controller-salt",
                        "pairingId": "guest-pairing",
                    ],
                    pairingSecrets: ["guest-pairing": "guest-secret"]
                ) == "account-controller-salt",
                try controllerKeyMaterial(
                    response: ["pairingId": "guest-pairing"],
                    pairingSecrets: ["guest-pairing": "guest-secret"]
                ) == "guest-secret" else {
                    throw AgentError.cryptography(
                        "Account and guest controller key selection failed"
                    )
                }
                let command = { (sequence: Int) in
                    SequencedInputCommand(
                        tabID: "tab",
                        input: String(sequence),
                        requestID: "request-\(sequence)",
                        sourceID: "controller",
                        expiresAt: Int.max,
                        streamID: "stream",
                        sequence: sequence
                    )
                }
                var lane = InputStreamLane()
                let buffered = lane.accept(command(2))
                let drained = lane.accept(command(1))
                guard buffered.ready.isEmpty,
                      !buffered.duplicate,
                      !buffered.overflow,
                      drained.ready.map(\.sequence) == [1, 2],
                      lane.nextSequence == 3 else {
                    throw AgentError.server(
                        "Sequenced input reorder compatibility failed"
                    )
                }
                print("TerminalDB remote agent self-test: passed")
                return
            }
            let agent = try RemoteAgent()
            try agent.run()
            dispatchMain()
        } catch {
            fputs("TerminalDBRemoteAgent: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
