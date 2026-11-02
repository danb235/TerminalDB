import Foundation
import Security

enum SharedAccountCodeIdentity {
    static var fixture: Bool {
        ProcessInfo.processInfo.environment["TERMINALDB_PEER_QA"] == "1" &&
            ProcessInfo.processInfo.environment["TERMINALDB_PEER_EPHEMERAL_IDENTITY"] == "1"
    }
    static func isClaude(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        if fixture { return url.path.hasPrefix(PeerPaths.root.path + "/") }
        var code: SecStaticCode?, requirement: SecRequirement?
        // Anthropic's signed native Claude Code distribution. Subscription
        // credentials must never be injected into an arbitrary executable.
        let rule = "anchor apple generic and identifier \"com.anthropic.claude-code\" and certificate leaf[subject.OU] = \"Q6L2SF6YDW\""
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
    }
    static func allowsLocalManagement(_ pid: pid_t) -> Bool {
        allowsLocalManagement(attributes: [kSecGuestAttributePid: pid])
    }
    static func allowsLocalManagement(audit: Data) -> Bool {
        allowsLocalManagement(attributes: [kSecGuestAttributeAudit: audit])
    }
    private static func allowsLocalManagement(attributes: [CFString: Any]) -> Bool {
        if fixture { return true }
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &guest) == errSecSuccess,
              let guest, SecCodeCheckValidity(guest, [], nil) == errSecSuccess else { return false }
        var info: CFDictionary?
        var guestStatic: SecStaticCode?
        guard SecCodeCopyStaticCode(guest, [], &guestStatic) == errSecSuccess, let guestStatic,
              SecCodeCopySigningInformation(guestStatic, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let hash = (info as? [CFString: Any])?[kSecCodeInfoUnique] as? Data else { return false }
        var app = Bundle.main.bundleURL
        if ["TerminalDBSessionHost.app", "TerminalDBPeerAgent.app"].contains(app.lastPathComponent) { for _ in 0..<4 { app.deleteLastPathComponent() } }
        let paths = [app.appendingPathComponent("Contents/MacOS/TerminalDB"),
                     app.appendingPathComponent("Contents/Library/LoginItems/TerminalDBPeerAgent.app/Contents/MacOS/TerminalDBPeerAgent")]
        return paths.contains { path in
            var expected: SecStaticCode?, details: CFDictionary?
            guard SecStaticCodeCreateWithPath(path as CFURL, [], &expected) == errSecSuccess, let expected,
                  SecStaticCodeCheckValidity(expected, [], nil) == errSecSuccess,
                  SecCodeCopySigningInformation(expected, SecCSFlags(rawValue: kSecCSSigningInformation), &details) == errSecSuccess else { return false }
            return (details as? [CFString: Any])?[kSecCodeInfoUnique] as? Data == hash
        }
    }
}
