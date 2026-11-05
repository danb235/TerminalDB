import Foundation

// Only these safe outcomes cross the AWS CLI boundary. Provider stderr stays
// bounded in private memory and is never used as display text or persisted.
enum SharedAWSCheckState: String {
    case ready, checking, signInRequired, networkUnavailable, accessDenied, checkFailed

    var status: String {
        switch self {
        case .ready: return "Ready to share"
        case .checking: return "Checking access…"
        case .signInRequired: return "AWS sign-in required"
        case .networkUnavailable: return "AWS connection unavailable"
        case .accessDenied: return "AWS access denied"
        case .checkFailed: return "AWS access could not be checked"
        }
    }
}

struct SharedAWSAccessCheck {
    let state: SharedAWSCheckState
    let checkedAt: Double
    let expiresAt: Double?
    let needsSharedRenewal: Bool

    init(state: SharedAWSCheckState, checkedAt: Double, expiresAt: Double?, needsSharedRenewal: Bool = false) {
        self.state = state; self.checkedAt = checkedAt; self.expiresAt = expiresAt
        self.needsSharedRenewal = needsSharedRenewal
    }

    var metadata: [String: Any] {
        var result: [String: Any] = ["state": state.rawValue, "checkedAt": checkedAt]
        if let expiresAt { result["expiresAt"] = expiresAt }
        if needsSharedRenewal { result["needsSharedRenewal"] = true }
        return result
    }
}

struct SharedAWSCommandFailure: Error {
    let state: SharedAWSCheckState

    static func classify(_ stderr: Data) -> SharedAWSCommandFailure {
        // Avoid creating an immutable String containing provider output. The
        // temporary ASCII-normalized copy is wiped after conservative matching.
        var bytes = stderr
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        bytes.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            for index in buffer.indices where (65...90).contains(buffer[index]) { buffer[index] += 32 }
        }
        func has(_ text: String) -> Bool { bytes.range(of: Data(text.utf8)) != nil }
        if has("accessdenied") || has("access denied") || has("forbiddenexception") ||
            has("not authorized to perform") || has("not authorised to perform") {
            return .init(state: .accessDenied)
        }
        if has("could not connect to the endpoint url") || has("could not connect to proxy url") ||
            has("connection was closed before we received a valid response") ||
            has("connect timeout on endpoint url") || has("read timeout on endpoint url") ||
            has("connection timed out") || has("network is unreachable") ||
            has("temporary failure in name resolution") || has("name or service not known") ||
            has("nodename nor servname provided") || has("ssl validation failed") ||
            has("throttling") || has("toomanyrequestsexception") || has("requestlimitexceeded") ||
            has("serviceunavailable") || has("internalserverexception") {
            return .init(state: .networkUnavailable)
        }
        // Known botocore login-required messages, not generic token exceptions.
        // A positively identified permission/network cause takes precedence:
        // refresh wrappers can contain both expiry text and the real failure.
        if has("your session has expired or credentials have changed. please reauthenticate using 'aws login'.") ||
            has("the sso session associated with this profile has expired or is otherwise invalid. to refresh this sso session run aws sso login") ||
            (has("error loading sso token: token for ") && has(" does not exist")) ||
            (has("invalidgrant") && has("createtoken")) {
            return .init(state: .signInRequired)
        }
        return .init(state: .checkFailed)
    }
}

enum SharedAWSChecksTests {
    static func run() throws -> Int {
        let cases: [(String, SharedAWSCheckState)] = [
            ("Your session has expired or credentials have changed. Please reauthenticate using 'aws login'.", .signInRequired),
            ("The SSO session associated with this profile has expired or is otherwise invalid. To refresh this SSO session run aws sso login with the corresponding profile.", .signInRequired),
            ("Error when retrieving token from sso: Token has expired and refresh failed", .checkFailed),
            ("Token has expired and refresh failed: an unknown underlying failure", .checkFailed),
            ("Error loading SSO Token: Token for synthetic does not exist", .signInRequired),
            ("An error occurred (InvalidGrantException) when calling the CreateToken operation", .signInRequired),
            ("Error when retrieving token from sso: Could not connect to the endpoint URL: synthetic", .networkUnavailable),
            ("Read timeout on endpoint URL: synthetic", .networkUnavailable),
            ("An error occurred (ThrottlingException) when calling GetRoleCredentials", .networkUnavailable),
            ("SSL validation failed for synthetic", .networkUnavailable),
            ("Token has expired and refresh failed: Could not connect to the endpoint URL: synthetic", .networkUnavailable),
            ("Token has expired and refresh failed: AccessDeniedException", .accessDenied),
            ("An error occurred (AccessDeniedException) when calling GetRoleCredentials", .accessDenied),
            ("User is not authorized to perform synthetic", .accessDenied),
            ("The config profile could not be found", .checkFailed),
            ("TokenRetrievalError: an unspecified provider error", .checkFailed),
            ("An error occurred (ExpiredToken) when calling GetCallerIdentity", .checkFailed),
            ("An error occurred (UnauthorizedException) when calling an unknown operation", .checkFailed),
            ("synthetic diagnostic without an AWS authentication requirement", .checkFailed),
            ("", .checkFailed)
        ]
        for (message, expected) in cases {
            guard SharedAWSCommandFailure.classify(Data(message.utf8)).state == expected else {
                throw PeerFailure("An AWS safe outcome classification regression failed.")
            }
        }
        return cases.count
    }
}
