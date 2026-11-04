import Foundation

enum AWSProfilePresentationTests {
    static func run() throws -> Int {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool) throws {
            guard value() else { throw PeerFailure("An AWS access presentation regression failed after \(checks) checks.") }
            checks += 1
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let future = now.addingTimeInterval(3600).timeIntervalSince1970
        let profile = AWSProfileDescriptor(name: "project-work", kind: "sso", region: "us-west-2",
            ssoStartURL: "https://example.awsapps.com/start", ssoRegion: "us-east-1",
            accountID: "111111111111", roleName: "Reader", ssoSessionName: "company-sso")
        func row(local: Bool = false, installed: Bool = true, auth: String = "expired",
                 available: Bool = true, status: String = "Ready", expires: Double? = nil,
                 checkState: String? = nil, checkedExpiry: Double? = nil, needsSharedRenewal: Bool = false) -> AWSProfilePresentation {
            var check: [String: Any] = ["needsSharedRenewal": needsSharedRenewal]
            if let checkState { check["state"] = checkState }
            if let checkedExpiry { check["expiresAt"] = checkedExpiry }
            return AWSProfilePresentation(id: profile.id, descriptor: profile,
                localNames: local ? [profile.name] : [], installedNames: installed ? [profile.name] : [],
                sharedNames: [profile.name], sourceNames: ["Office Mac"], available: available,
                expiration: expires ?? future, status: status,
                authentication: AWSProfileAuthentication(["state": auth, "sessionName": "company-sso", "expiresAt": now.addingTimeInterval(-60).timeIntervalSince1970]),
                sourceCheck: AWSSourceCheck(check))
        }
        func state(_ row: AWSProfilePresentation, source: Bool = false) -> AWSProfileRowState {
            row.rowState(isSource: source, sourceStatus: nil, isSigningIn: false, now: now)
        }
        // Valid credentials, rather than an OAuth cache timestamp, determine
        // readiness. Healthy rows have no renewal task or expiry warning.
        for local in [false, true] {
            for auth in ["current", "expired", "missing", "unknown", "notApplicable"] {
                let receiver = state(row(local: local, auth: auth))
                try check(receiver.primaryAction == .ready && receiver.primaryAction?.title == "Ready")
                try check(receiver.secondaryAction == nil && !receiver.needsAttention)
                try check(receiver.authenticationText == "From Office Mac")
                try check(!receiver.availabilityText.contains("until") && !receiver.authenticationText.contains("SSO"))
                let source = state(row(local: true, auth: auth), source: true)
                try check(source.primaryAction == .ready && source.secondaryAction == nil)
                try check(source.availabilityText == "Renews automatically" && source.authenticationText == "Shared from This Mac")
            }
        }
        for auth in ["expired", "missing", "unknown", "current"] {
            let local = state(row(local: true, installed: false, auth: auth, available: false))
            try check(local.primaryAction == .shareAccess && local.secondaryAction == nil)
            try check(local.availabilityText == "Not checked" && !local.needsAttention)
        }
        let verified = state(row(local: true, installed: false, available: false, checkState: "ready", checkedExpiry: future))
        try check(verified.primaryAction == .shareAccess && verified.availabilityText == "Ready · Not shared")
        let staleVerified = state(row(local: true, installed: false, available: false, checkState: "ready", checkedExpiry: now.timeIntervalSince1970 - 1))
        try check(staleVerified.availabilityText == "Not checked")
        let noExpiry = state(row(local: true, installed: false, available: false, checkState: "ready"))
        try check(noExpiry.availabilityText == "Not checked")

        let renewalRequired = state(row(local: true, checkState: "signInRequired"), source: true)
        try check(renewalRequired.primaryAction == .ready && renewalRequired.secondaryAction == .signIn)
        try check(renewalRequired.needsAttention && renewalRequired.availabilityText.contains("renewal"))
        let expiredRequired = state(row(local: true, available: false, checkState: "signInRequired"), source: true)
        try check(expiredRequired.primaryAction == .signIn && expiredRequired.needsAttention)
        let ignoredOldLocalFailure = state(row(local: true, checkState: "signInRequired"))
        try check(ignoredOldLocalFailure.primaryAction == .ready && ignoredOldLocalFailure.secondaryAction == nil)
        let legacyStatus = row(local: true).rowState(isSource: true, sourceStatus: "Sign in on this Mac to renew", isSigningIn: false, now: now)
        try check(legacyStatus.primaryAction == .ready && legacyStatus.secondaryAction == nil)

        for failure in ["accessDenied", "checkFailed"] {
            for source in [false, true] {
                let failed = state(row(local: true, checkState: failure, checkedExpiry: future), source: source)
                try check(failed.primaryAction != .ready && failed.primaryAction != .signIn && failed.needsAttention)
            }
            let local = state(row(local: true, installed: false, available: false, checkState: failure, checkedExpiry: future))
            try check(local.primaryAction != .ready && !local.availabilityText.hasPrefix("Ready"))
            // A failed native provider must not hide a valid shared import.
            let migration = state(row(local: true, installed: false, checkState: failure))
            try check(migration.primaryAction == .useSharedAccess && migration.secondaryAction == .shareAccess)
        }
        let offlineCached = state(row(local: true, checkState: "networkUnavailable"), source: true)
        try check(offlineCached.primaryAction == .ready && offlineCached.needsAttention)
        let offlineEmpty = state(row(local: true, available: false, checkState: "networkUnavailable"), source: true)
        try check(offlineEmpty.primaryAction == .networkUnavailable && offlineEmpty.primaryAction != .signIn)
        let missingShared = state(row(available: false, checkState: "checkFailed", needsSharedRenewal: true))
        try check(missingShared.primaryAction == .syncNow && missingShared.secondaryAction == nil)
        let renewedShared = state(row(checkState: "checkFailed", needsSharedRenewal: true))
        try check(renewedShared.primaryAction == .ready && !renewedShared.needsAttention)
        let waiting = state(row(available: false, status: "Expired"))
        try check(waiting.primaryAction == .syncNow && waiting.secondaryAction == nil)
        let stale = state(row(expires: now.timeIntervalSince1970 - 1))
        try check(stale.primaryAction == .syncNow)
        let malformed = state(row(expires: .nan))
        try check(malformed.primaryAction == .syncNow)
        let retainedCheckMustNotOverride = state(row(local: true, available: false, checkState: "ready", checkedExpiry: future))
        try check(retainedCheckMustNotOverride.primaryAction == .syncNow)
        let fresh = state(row(installed: false))
        try check(fresh.primaryAction == .useSharedAccess && fresh.availabilityText == "Ready to use")
        let sourceNeedsAlias = state(row(installed: false), source: true)
        try check(sourceNeedsAlias.primaryAction == .useSharedAccess)
        let conflict = state(row(status: "Choose Account Again"))
        try check(conflict.primaryAction == .review && conflict.needsAttention)
        let signing = row().rowState(isSource: false, sourceStatus: nil, isSigningIn: true, now: now)
        try check(signing.primaryAction == .signingIn && signing.availabilityText.isEmpty)
        let checking = state(row(local: true, available: false, checkState: "checking"), source: true)
        try check(checking.primaryAction == .refreshing && checking.primaryAction?.title == "Checking…")
        let healthyChecking = state(row(local: true, checkState: "checking"), source: true)
        try check(healthyChecking.primaryAction == .ready)
        try check(AWSSourceCheck(["state": "arbitrary"]).state == "notChecked")
        try check(AWSSourceCheck(["state": "accessDenied"]).guidance != AWSSourceCheck(["state": "networkUnavailable"]).guidance)
        return checks
    }
}
