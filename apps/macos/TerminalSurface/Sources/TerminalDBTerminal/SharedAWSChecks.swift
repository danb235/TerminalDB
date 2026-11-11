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
    // AWS CLI 2.x reports an ended IAM Identity Center session and an
    // unreachable OIDC endpoint with the same bare refresh failure text,
    // because botocore discards the underlying cause. Such a failure carries
    // the provisional `.signInRequired` state and must be resolved with a
    // reachability probe of the session's OIDC endpoint before it is shown.
    let requiresReachabilityProbe: Bool

    init(state: SharedAWSCheckState, requiresReachabilityProbe: Bool = false) {
        self.state = state; self.requiresReachabilityProbe = requiresReachabilityProbe
    }

    // Reachable OIDC means AWS refused the refresh, so the session is over.
    // Unreachable means the refresh never reached AWS.
    func resolved(reachable: Bool) -> SharedAWSCheckState {
        guard requiresReachabilityProbe else { return state }
        return reachable ? .signInRequired : .networkUnavailable
    }

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
        // No network or permission cause was identified above, so this bare
        // wrapper stays ambiguous until the OIDC endpoint has been probed.
        if has("token has expired and refresh failed") {
            return .init(state: .signInRequired, requiresReachabilityProbe: true)
        }
        return .init(state: .checkFailed)
    }
}

// Distinguishes an ended Identity Center session from a network failure
// when AWS CLI reports only that the token refresh failed. The probe sends
// no token, cookie or credential, and any HTTP response at all proves that
// the regional OIDC endpoint was reachable.
enum SharedAWSReachability {
    static func oidcEndpoint(region: String) -> URL? {
        guard region.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)+-[0-9]+$"#, options: .regularExpression) != nil else { return nil }
        return URL(string: "https://oidc." + region + ".amazonaws.com/")
    }

    // Disposable tests never use the network. A fixture switch file selects
    // the unreachable outcome so both resolutions stay deterministic.
    static func probe(region: String, root: URL, queue: DispatchQueue, timeout: Double = 5,
                      completion: @escaping (Bool) -> Void) {
        if SharedAccountCodeIdentity.fixture {
            let unreachable = FileManager.default.fileExists(atPath: root.appendingPathComponent("aws-fixture/sso-unreachable").path)
            queue.async { completion(!unreachable) }
            return
        }
        guard let url = oidcEndpoint(region: region) else { queue.async { completion(false) }; return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: configuration)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        let task = session.dataTask(with: request) { _, response, _ in
            let reachable = response is HTTPURLResponse
            queue.async { completion(reachable) }
        }
        task.resume()
        session.finishTasksAndInvalidate()
    }
}

enum SharedAWSChecksTests {
    static func run() throws -> Int {
        // The third field marks provisional outcomes that the service must
        // resolve with an OIDC reachability probe before showing them.
        let cases: [(String, SharedAWSCheckState, Bool)] = [
            ("Your session has expired or credentials have changed. Please reauthenticate using 'aws login'.", .signInRequired, false),
            ("The SSO session associated with this profile has expired or is otherwise invalid. To refresh this SSO session run aws sso login with the corresponding profile.", .signInRequired, false),
            ("Error when retrieving token from sso: Token has expired and refresh failed", .signInRequired, true),
            ("aws: [ERROR]: Error when retrieving token from sso: Token has expired and refresh failed\n", .signInRequired, true),
            ("Token has expired and refresh failed: an unknown underlying failure", .signInRequired, true),
            ("Error loading SSO Token: Token for synthetic does not exist", .signInRequired, false),
            ("An error occurred (InvalidGrantException) when calling the CreateToken operation", .signInRequired, false),
            ("Error when retrieving token from sso: Could not connect to the endpoint URL: synthetic", .networkUnavailable, false),
            ("Read timeout on endpoint URL: synthetic", .networkUnavailable, false),
            ("An error occurred (ThrottlingException) when calling GetRoleCredentials", .networkUnavailable, false),
            ("SSL validation failed for synthetic", .networkUnavailable, false),
            ("Token has expired and refresh failed: Could not connect to the endpoint URL: synthetic", .networkUnavailable, false),
            ("Token has expired and refresh failed: AccessDeniedException", .accessDenied, false),
            ("An error occurred (AccessDeniedException) when calling GetRoleCredentials", .accessDenied, false),
            ("User is not authorized to perform synthetic", .accessDenied, false),
            ("The config profile could not be found", .checkFailed, false),
            ("TokenRetrievalError: an unspecified provider error", .checkFailed, false),
            ("An error occurred (ExpiredToken) when calling GetCallerIdentity", .checkFailed, false),
            ("An error occurred (UnauthorizedException) when calling an unknown operation", .checkFailed, false),
            ("synthetic diagnostic without an AWS authentication requirement", .checkFailed, false),
            ("", .checkFailed, false)
        ]
        for (message, expected, probe) in cases {
            let failure = SharedAWSCommandFailure.classify(Data(message.utf8))
            guard failure.state == expected, failure.requiresReachabilityProbe == probe,
                  failure.resolved(reachable: true) == expected,
                  failure.resolved(reachable: false) == (probe ? .networkUnavailable : expected) else {
                throw PeerFailure("An AWS safe outcome classification regression failed.")
            }
        }
        guard SharedAWSReachability.oidcEndpoint(region: "us-east-1")?.absoluteString == "https://oidc.us-east-1.amazonaws.com/",
              SharedAWSReachability.oidcEndpoint(region: "evil.example.com/x") == nil,
              SharedAWSReachability.oidcEndpoint(region: "") == nil else {
            throw PeerFailure("An AWS reachability endpoint regression failed.")
        }
        return cases.count + 1
    }
}
