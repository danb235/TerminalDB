import Foundation

enum AWSProfilePresentationTests {
    static func run() throws -> Int {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool) throws {
            guard value() else { throw PeerFailure("An AWS access presentation regression failed after \(checks) checks.") }
            checks += 1
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let profile = AWSProfileDescriptor(name: "project-work", kind: "sso", region: "us-west-2",
            ssoStartURL: "https://example.awsapps.com/start", ssoRegion: "us-east-1",
            accountID: "111111111111", roleName: "Reader", ssoSessionName: "company-sso")
        func row(local: Bool = false, installed: Bool = true, auth: String = "expired",
                 available: Bool = true, status: String = "Ready", expires: Double? = nil) -> AWSProfilePresentation {
            AWSProfilePresentation(id: profile.id, descriptor: profile,
                localNames: local ? [profile.name] : [], installedNames: installed ? [profile.name] : [],
                sharedNames: [profile.name], sourceNames: ["Office Mac"], available: available,
                expiration: expires ?? now.addingTimeInterval(3600).timeIntervalSince1970,
                status: status, authentication: AWSProfileAuthentication(["state": auth,
                    "sessionName": "company-sso", "expiresAt": now.addingTimeInterval(auth == "current" ? 3600 : -60).timeIntervalSince1970]))
        }

        // Keeping an original native profile for restoration must not turn its
        // old browser token into a requirement for the mapped shared provider.
        for local in [false, true] {
            for auth in ["current", "expired", "missing", "unknown", "notApplicable"] {
                let state = row(local: local, auth: auth).rowState(isSource: false, sourceStatus: nil, isSigningIn: false, now: now)
                try check(state.primaryAction == .ready)
                try check(state.secondaryAction == nil && !state.needsAttention)
                try check(state.authenticationText == "From Office Mac")
                try check(!state.authenticationText.contains("SSO"))
                try check(state.availabilityText.hasPrefix("Access until "))
                try check(state.showsAuthentication)
            }
        }

        // Receiving metadata is not a completed local CLI setup: a native
        // alias must still be explicitly migrated before it uses shared keys.
        let beforeMigration = row(local: true, installed: false).rowState(isSource: false, sourceStatus: nil, isSigningIn: false, now: now)
        try check(beforeMigration.primaryAction == .useSharedAccess)
        try check(beforeMigration.secondaryAction == .shareAccess)
        try check(!beforeMigration.needsAttention)
        try check(beforeMigration.availabilityText.hasPrefix("Available until "))
        let freshReceiver = row(installed: false, auth: "missing").rowState(isSource: false, sourceStatus: nil, isSigningIn: false, now: now)
        try check(freshReceiver.primaryAction == .useSharedAccess && freshReceiver.secondaryAction == nil)

        // An unavailable shared provider is recovered through synchronization;
        // signing in locally is an explicit fallback, even with an old alias.
        for auth in ["current", "expired", "missing"] {
            let state = row(local: true, auth: auth, available: false, status: "Expired", expires: now.addingTimeInterval(-1).timeIntervalSince1970)
                .rowState(isSource: false, sourceStatus: nil, isSigningIn: false, now: now)
            try check(state.primaryAction == .syncNow && state.secondaryAction == .signIn)
            try check(state.needsAttention && state.availabilityText == "Shared access expired")
            try check(state.authenticationText == "From Office Mac")
        }
        let staleAvailable = row(local: true, expires: now.addingTimeInterval(-1).timeIntervalSince1970)
            .rowState(isSource: false, sourceStatus: nil, isSigningIn: false, now: now)
        try check(staleAvailable.primaryAction == .syncNow)
        let invalidExpiry = row(expires: .nan).rowState(isSource: false, sourceStatus: nil, isSigningIn: false, now: now)
        try check(invalidExpiry.primaryAction == .syncNow)
        let conflict = row(local: true, auth: "current", status: "Choose Account Again")
            .rowState(isSource: false, sourceStatus: nil, isSigningIn: false, now: now)
        try check(conflict.primaryAction == .review && conflict.needsAttention)

        let localSignedIn = row(local: true, installed: false, auth: "current", available: false)
            .rowState(isSource: false, sourceStatus: nil, isSigningIn: false, now: now)
        try check(localSignedIn.primaryAction == .shareAccess && localSignedIn.secondaryAction == .signInAgain)
        try check(!localSignedIn.needsAttention && localSignedIn.availabilityText == "Not shared")
        let localExpired = row(local: true, installed: false, available: false)
            .rowState(isSource: false, sourceStatus: nil, isSigningIn: false, now: now)
        try check(localExpired.primaryAction == .signIn && localExpired.secondaryAction == .shareAccess)

        let source = row(local: true, installed: false, auth: "current")
            .rowState(isSource: true, sourceStatus: "Ready to share", isSigningIn: false, now: now)
        try check(source.primaryAction == .refreshAccess && source.secondaryAction == .signInAgain)
        try check(source.authenticationText == "SSO signed in" && !source.authenticationText.contains("company-sso"))
        try check(source.authenticationTooltip.contains("company-sso"))
        let newSourceWithoutAlias = row(installed: false, auth: "current")
            .rowState(isSource: true, sourceStatus: "Ready to share", isSigningIn: false, now: now)
        try check(newSourceWithoutAlias.primaryAction == .useSharedAccess)
        try check(newSourceWithoutAlias.secondaryAction == .refreshAccess && !newSourceWithoutAlias.needsAttention)
        let expiredSourceWithoutAlias = row(installed: false)
            .rowState(isSource: true, sourceStatus: nil, isSigningIn: false, now: now)
        try check(expiredSourceWithoutAlias.primaryAction == .useSharedAccess && expiredSourceWithoutAlias.secondaryAction == .signIn)
        let expiredSource = row(local: true, installed: false)
            .rowState(isSource: true, sourceStatus: nil, isSigningIn: false, now: now)
        try check(expiredSource.primaryAction == .signIn && expiredSource.secondaryAction == .refreshAccess)
        try check(expiredSource.needsAttention && expiredSource.availabilityText.hasPrefix("Access until "))
        let failedRoleRenewal = row(local: true, installed: false, auth: "current", available: false)
            .rowState(isSource: true, sourceStatus: "Sign in on this Mac to renew", isSigningIn: false, now: now)
        try check(failedRoleRenewal.primaryAction == .refreshAccess)
        try check(failedRoleRenewal.authenticationText == "SSO signed in" && failedRoleRenewal.availabilityText == "Access needs renewal")
        let refreshing = row(local: true, installed: false, auth: "current")
            .rowState(isSource: true, sourceStatus: "Renewing…", isSigningIn: false, now: now)
        try check(refreshing.primaryAction == .refreshing && refreshing.secondaryAction == nil)
        try check(!refreshing.needsAttention && refreshing.availabilityText == "Updating access…")
        let signingIn = row(local: true).rowState(isSource: false, sourceStatus: nil, isSigningIn: true, now: now)
        try check(signingIn.primaryAction == .signingIn && signingIn.secondaryAction == nil)
        try check(signingIn.authenticationText == "From Office Mac" && !signingIn.needsAttention)

        var browserLogin = row(local: true, installed: false, auth: "notApplicable", available: false)
        browserLogin.descriptor = AWSProfileDescriptor(name: "console-work", kind: "login", loginSession: "arn:aws:iam::111111111111:user/example")
        browserLogin.id = browserLogin.descriptor.id
        let consoleState = browserLogin.rowState(isSource: false, sourceStatus: nil, isSigningIn: false, now: now)
        try check(consoleState.primaryAction == .shareAccess && consoleState.secondaryAction == .signIn)
        try check(!consoleState.showsAuthentication && !consoleState.needsAttention)
        browserLogin.installedNames = ["console-work"]
        browserLogin.available = true
        let consoleReceiver = browserLogin.rowState(isSource: false, sourceStatus: nil, isSigningIn: false, now: now)
        try check(consoleReceiver.primaryAction == .ready && consoleReceiver.showsAuthentication)
        try check(consoleReceiver.authenticationText == "From Office Mac" && !consoleReceiver.needsAttention)
        return checks
    }
}
