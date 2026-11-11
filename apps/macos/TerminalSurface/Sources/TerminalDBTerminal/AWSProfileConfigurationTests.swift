import Foundation
import Darwin
import CryptoKit

enum AWSProfileConfigurationTests {
    static func run(root: URL) throws -> Int {
        let base = root.appendingPathComponent("aws-configuration")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let config = base.appendingPathComponent("config")
        let managed = AWSProfileConfiguration(configURL: config, root: base.appendingPathComponent("managed"), ssoCacheURL: base.appendingPathComponent("sso-cache"))
        var count = 0
        func check(_ value: @autoclosure () throws -> Bool) throws {
            guard try value() else { throw PeerFailure("An AWS profile configuration regression failed after \(count) checks.") }; count += 1
        }
        func rejected(_ operation: () throws -> Void) -> Bool { do { try operation(); return false } catch { return true } }
        func write(_ text: String) throws { try Data(text.utf8).write(to: config); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path) }
        let original = """
        # Keep this ordinary configuration exactly.
        [default]
        region = us-west-2
        output = json

        [profile workspace] # ordinary header comment
        # Preserve comments inside the chosen profile, too.
        sso_session = work-session
        sso_account_id = 123456789012
        sso_role_name = Developer
        region = us-east-1
        endpoint_url = https://unrelated-endpoint.invalid
        ca_bundle = /tmp/unrelated-ca
        plugins = unrelated

        [sso-session work-session]
        sso_start_url = https://example.awsapps.com/start
        sso_region = us-east-1
        sso_registration_scopes = sso:account:access

        [profile legacy]
        sso_start_url = https://example.awsapps.com/start
        sso_region = us-east-1
        sso_account_id = 123456789012
        sso_role_name = Developer
        region = us-west-2

        [profile web-login]
        login_session = arn:aws:iam::123456789012:user/synthetic
        region = us-east-1

        [profile static]
        aws_access_key_id = fixture-not-a-real-aws-key
        aws_secret_access_key = fixture-not-a-real-aws-secret

        [profile chained]
        sso_start_url = https://example.awsapps.com/start
        sso_region = us-east-1
        sso_account_id = 123456789012
        sso_role_name = Developer
        credential_process = /tmp/do-not-run

        """.replacingOccurrences(of: "\n", with: "\r\n")
        try write(original)
        let discovered = try managed.discover()
        try check(discovered.count == 3)
        let source = discovered.first { $0.name == "workspace" }!
        let legacy = discovered.first { $0.name == "legacy" }!
        let login = discovered.first { $0.name == "web-login" }!
        try check(source.id == legacy.id)
        try check(source.id != login.id)
        try check(try managed.configuredNames() == ["chained", "default", "legacy", "static", "web-login", "workspace"])
        func object(_ profile: AWSProfileDescriptor) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as! [String: Any]
        }
        var remoteAlias = source; remoteAlias.name = "office-access"; remoteAlias.region = "eu-west-1"
        let received: [String: Any] = ["profileId": source.id, "descriptor": try object(remoteAlias), "profileNames": ["office-access", "team-access"], "sourceNames": ["Office Mac", "Travel Mac"], "available": true, "status": "Ready", "expires": 2000000000.0]
        let genericCatalog: [String: Any] = ["profiles": try [object(source), object(legacy)], "accounts": [received]]
        let grouped = AWSProfilePresentation.rows(catalog: genericCatalog)
        try check(grouped.count == 1 && grouped[0].localNames == ["legacy", "workspace"])
        try check(grouped[0].name == "legacy" && grouped[0].hasLocalProfile)
        try check(grouped[0].sourceNames == ["Office Mac", "Travel Mac"] && grouped[0].available)
        try check(grouped[0].sharedNames.contains("team-access") && grouped[0].sharedNames.contains("office-access"))
        let beforeReconnect = AWSProfilePresentation.rows(catalog: ["profiles": try [object(source), object(legacy)]])
        try check(beforeReconnect.count == 1 && beforeReconnect[0].name == grouped[0].name && !beforeReconnect[0].available)
        let different = AWSProfileDescriptor(name: "workspace", kind: "sso", ssoStartURL: "https://another.awsapps.com/start", ssoRegion: "us-east-1", accountID: "999999999999", roleName: "Reader")
        let conflictCatalog: [String: Any] = ["profiles": try [object(source)], "accounts": [["profileId": different.id, "descriptor": try object(different), "available": true]]]
        let conflicting = AWSProfilePresentation.rows(catalog: conflictCatalog)
        try check(conflicting.count == 2 && AWSProfilePresentation.namesConflict("workspace", rows: conflicting))
        let remoteRow = conflicting.first { $0.id == different.id }!
        try check(remoteRow.suggestedName(rows: conflicting) == "workspace-9999")
        try check(remoteRow.suggestedName(rows: conflicting, occupiedNames: ["workspace", "workspace-9999", "workspace-9999-2"]) == "workspace-9999-3")
        let mapped = AWSProfilePresentation.rows(catalog: ["profiles": try [object(source)], "accounts": [received], "installed": [["profileId": source.id, "descriptor": try object(source), "targetName": "my-local-name"]]])
        try check(mapped.count == 1 && mapped[0].name == "my-local-name" && mapped[0].isInstalled)
        let twoAliases = AWSProfilePresentation.rows(catalog: ["profiles": try [object(source), object(legacy)], "installed": [["profileId": source.id, "descriptor": try object(legacy), "targetName": "legacy"]]])
        try check(twoAliases[0].suggestedAdditionalName(rows: twoAliases, occupiedNames: ["legacy", "workspace"]) == "workspace")
        let installedOnly = AWSProfilePresentation.rows(catalog: ["profiles": [], "installed": [["profileId": source.id, "descriptor": try object(source), "targetName": "workspace"], ["profileId": source.id, "descriptor": try object(source), "targetName": "workspace-2"]]])
        try check(installedOnly.count == 1 && installedOnly[0].installedNames == ["workspace", "workspace-2"])
        try check(installedOnly[0].suggestedAdditionalName(rows: installedOnly) == "workspace-3")
        try check(installedOnly[0].suggestedAdditionalName(rows: installedOnly, occupiedNames: ["workspace-3", "workspace-4"]) == "workspace-5")
        try check(!Set(installedOnly[0].installedNames).contains(installedOnly[0].suggestedAdditionalName(rows: installedOnly)))
        let privateSource = AWSProfilePresentation.rows(catalog: ["profiles": try [object(remoteAlias)], "configuredProfileIDs": [], "accounts": [received]])
        try check(privateSource.count == 1 && !privateSource[0].hasLocalProfile && privateSource[0].localNames.isEmpty)
        var unicode = different; unicode.name = String(repeating: "🖥", count: 32)
        let unicodeRows = AWSProfilePresentation.rows(catalog: ["profiles": [], "accounts": [["profileId": unicode.id, "descriptor": try object(unicode)]]])
        try check(unicodeRows.count == 1 && AWSProfileDescriptor.validName(unicodeRows[0].suggestedName(rows: unicodeRows, occupiedNames: [unicode.name])))
        var unicodeInstalled = unicodeRows[0]; unicodeInstalled.installedNames = [unicode.name]
        try check(AWSProfileDescriptor.validName(unicodeInstalled.suggestedAdditionalName(rows: [unicodeInstalled], occupiedNames: [unicode.name])))
        var malformed = try object(source); malformed["id"] = String(repeating: "0", count: 64)
        try check(AWSProfilePresentation.rows(catalog: ["profiles": [malformed]]).isEmpty)
        try check(try Data(contentsOf: config) == Data(original.utf8))
        let backing = try managed.prepareBackingConfig(source)
        let backingText = try String(contentsOf: backing, encoding: .utf8)
        try check(backingText.contains("[profile workspace]") && backingText.contains("[sso-session work-session]"))
        try check(!backingText.contains("endpoint_url") && !backingText.contains("ca_bundle") && !backingText.contains("plugins"))
        try check(!backingText.contains("static") && !backingText.contains("credential_process"))
        let aliasBacking = try managed.prepareBackingConfig(legacy)
        try check(aliasBacking != backing && (try String(contentsOf: backing, encoding: .utf8)) == backingText)
        try check(try managed.loginArguments(for: source) == ["sso", "login", "--sso-session", "work-session"])
        try check(try managed.loginArguments(for: login) == ["login", "--profile", "web-login"])
        try check(rejected { _ = try managed.install(source, targetName: "workspace", launcherPath: "/Applications/TerminalDB.app/helper") })
        let aliasReplacement = try managed.install(source, targetName: "legacy", launcherPath: "/Applications/TerminalDB.app/helper", allowReplacingSource: true)
        try check(aliasReplacement.targetName == "legacy" && aliasReplacement.descriptor.id == source.id)
        try managed.restore(aliasReplacement)
        try check(try Data(contentsOf: config) == Data(original.utf8))
        let helper = "/Applications/TerminalDB 'test' \\\".app/helper"
        let installation = try managed.install(source, targetName: "workspace", launcherPath: helper, allowReplacingSource: true)
        let changed = try String(contentsOf: config, encoding: .utf8)
        let defaultBytes = original.components(separatedBy: "[profile workspace]").first!
        let untouchedSuffix = original.components(separatedBy: "[sso-session work-session]").last!
        try check(changed.hasPrefix(defaultBytes))
        try check(changed.hasSuffix("[sso-session work-session]" + untouchedSuffix))
        let publicProfile = changed.components(separatedBy: "[profile workspace]").last!.components(separatedBy: "[sso-session work-session]").first!
        try check(!publicProfile.contains("sso_session =") && !publicProfile.contains("sso_account_id =") && !publicProfile.contains("sso_role_name ="))
        try check(publicProfile.contains("# Preserve comments") && publicProfile.contains("endpoint_url = https://unrelated-endpoint.invalid"))
        try check(publicProfile.contains("credential_process = \"") && publicProfile.contains("--aws-credentials") && publicProfile.contains(source.id))
        try check(try Data(contentsOf: URL(fileURLWithPath: installation.backupPath)) == Data(original.utf8))
        try check(try managed.installations() == [installation])
        try check(try managed.discover().contains { $0.name == source.name && $0.id == source.id })
        try check(try managed.install(source, targetName: "workspace", launcherPath: helper, allowReplacingSource: true) == installation)
        // A user edit in another section survives both migration and restoration.
        let elsewhere = changed.replacingOccurrences(of: "output = json", with: "output = yaml")
        try write(elsewhere)
        try managed.restore(installation)
        try check(try String(contentsOf: config, encoding: .utf8) == original.replacingOccurrences(of: "output = json", with: "output = yaml"))
        try check(try managed.installations().isEmpty)
        let alternate = try managed.install(source, targetName: "workspace-shared", launcherPath: helper)
        try check(alternate.originalProfile == nil)
        try check(try String(contentsOf: config, encoding: .utf8).contains("[profile workspace-shared]\r\n"))
        try managed.restore(alternate)
        try check(try String(contentsOf: config, encoding: .utf8) == original.replacingOccurrences(of: "output = json", with: "output = yaml"))
        // Never overwrite a changed public profile or roll back unrelated edits.
        let changedProfile = try managed.install(source, targetName: "workspace-shared", launcherPath: helper)
        let beforeUnsafeRestore = try String(contentsOf: config, encoding: .utf8).replacingOccurrences(of: "--aws-credentials", with: "--user-edited")
        try write(beforeUnsafeRestore)
        try check(rejected { try managed.restore(changedProfile) })
        try check(try String(contentsOf: config, encoding: .utf8) == beforeUnsafeRestore)
        try check(rejected { _ = try managed.install(source, targetName: "workspace-shared", launcherPath: helper) })
        // A received same-name mapping retains the original local session, not
        // the sending Mac's alias; its sibling local roles use that same login.
        try write(original)
        var incoming = source; incoming.ssoSessionName = "sending-mac-session"
        let receivedMapping = try managed.install(incoming, targetName: "workspace", launcherPath: helper, allowReplacingSource: true)
        try check(try managed.resolvedSSOSessionName(for: incoming) == "work-session")
        try check(try managed.loginArguments(for: incoming) == ["sso", "login", "--sso-session", "work-session"])
        try managed.restore(receivedMapping)
        try check(try Data(contentsOf: config) == Data(original.utf8))

        var legacyIncoming = legacy; legacyIncoming.name = "received-legacy"
        let namedOriginal = try managed.install(legacyIncoming, targetName: "workspace", launcherPath: helper, allowReplacingSource: true)
        try check(try managed.resolvedSSOSessionName(for: legacyIncoming) == "work-session")
        try check(try String(contentsOf: managed.prepareBackingConfig(legacyIncoming), encoding: .utf8).contains("sso_session = work-session"))
        try managed.restore(namedOriginal)
        var namedIncoming = source; namedIncoming.name = "received-named"
        let legacyOriginal = try managed.install(namedIncoming, targetName: "legacy", launcherPath: helper, allowReplacingSource: true)
        try check(try managed.resolvedSSOSessionName(for: namedIncoming) == nil)
        try check(try managed.loginArguments(for: namedIncoming) == ["sso", "login", "--profile", "received-named"])
        try check(!(try String(contentsOf: managed.prepareBackingConfig(namedIncoming), encoding: .utf8)).contains("sso_session ="))
        try managed.restore(legacyOriginal)
        try check(try Data(contentsOf: config) == Data(original.utf8))

        // SSO freshness does not borrow the account's longer-lived role cache.
        let cache = base.appendingPathComponent("sso-cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        func cachePath(_ key: String) -> URL {
            cache.appendingPathComponent(Insecure.SHA1.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".json")
        }
        let tokenFile = cachePath("work-session")
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var metadata: [String: Any] = ["startUrl": source.ssoStartURL, "region": source.ssoRegion,
                                     "expiresAt": ISO8601DateFormatter().string(from: now.addingTimeInterval(3600)),
                                     "accessToken": "synthetic-sso-access", "refreshToken": "synthetic-refresh"]
        func saveMetadata() throws {
            try JSONSerialization.data(withJSONObject: metadata).write(to: tokenFile)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)
        }
        try check(managed.authenticationStatus(for: source, now: now)["state"] as? String == "missing")
        try saveMetadata()
        let current = managed.authenticationStatus(for: source, now: now)
        try check(current["state"] as? String == "current" && current["sessionName"] as? String == "work-session")
        try check(current["expiresAt"] as? Double == now.addingTimeInterval(3600).timeIntervalSince1970)
        let statusText = String(data: try JSONSerialization.data(withJSONObject: current), encoding: .utf8)!
        try check(!statusText.contains("synthetic") && !statusText.contains("accessToken") && !statusText.contains("refreshToken"))
        let otherAccount = AWSProfileDescriptor(name: "project-data", kind: "sso", ssoStartURL: source.ssoStartURL, ssoRegion: source.ssoRegion, accountID: "999999999999", roleName: "Reader", ssoSessionName: "work-session")
        try check(managed.authenticationStatus(for: otherAccount, now: now)["expiresAt"] as? Double == current["expiresAt"] as? Double)
        metadata["expiresAt"] = ISO8601DateFormatter().string(from: now.addingTimeInterval(-1)); try saveMetadata()
        try check(managed.authenticationStatus(for: source, now: now)["state"] as? String == "expired")
        try check(managed.authenticationStatus(for: otherAccount, now: now)["state"] as? String == "expired")
        metadata["expiresAt"] = "2033-05-18T04:33:20.000Z"; try saveMetadata()
        try check(managed.authenticationStatus(for: source, now: now)["state"] as? String == "current")
        metadata["expiresAt"] = "2033-05-18T04:33:20UTC"; try saveMetadata()
        try check(managed.authenticationStatus(for: source, now: now)["state"] as? String == "current")
        metadata["startUrl"] = "https://different.awsapps.com/start"; try saveMetadata()
        try check(managed.authenticationStatus(for: source, now: now)["state"] as? String == "unknown")
        metadata["startUrl"] = source.ssoStartURL; metadata.removeValue(forKey: "accessToken"); try saveMetadata()
        try check(managed.authenticationStatus(for: source, now: now)["state"] as? String == "unknown")
        metadata["accessToken"] = "synthetic-sso-access"; try saveMetadata()
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: tokenFile.path)
        try check(managed.authenticationStatus(for: source, now: now)["state"] as? String == "unknown")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)
        try Data(repeating: 65, count: 65_537).write(to: tokenFile)
        try check(managed.authenticationStatus(for: source, now: now)["state"] as? String == "unknown")
        try FileManager.default.removeItem(at: tokenFile)
        let cacheTarget = cache.appendingPathComponent("other-cache")
        try Data("{}".utf8).write(to: cacheTarget)
        try FileManager.default.createSymbolicLink(at: tokenFile, withDestinationURL: cacheTarget)
        try check(managed.authenticationStatus(for: source, now: now)["state"] as? String == "unknown")
        try FileManager.default.removeItem(at: tokenFile)
        try saveMetadata()
        try FileManager.default.copyItem(at: tokenFile, to: cachePath(legacy.ssoStartURL))
        try check(managed.authenticationStatus(for: legacy, now: now)["state"] as? String == "current")
        try check(managed.authenticationStatus(for: login, now: now)["state"] as? String == "notApplicable")
        try check(try Data(contentsOf: config) == Data(original.utf8))

        // Session cache metadata, sandbox copies and removal touch only the
        // selected session's cache file, never sibling sessions.
        let cacheStatus = managed.ssoSessionCacheStatus(for: source, now: now)
        try check(cacheStatus.present && cacheStatus.readable && cacheStatus.hasRefreshToken && cacheStatus.accessTokenCurrent && cacheStatus.modifiedAt != nil)
        try check(managed.ssoSessionCacheStatus(for: source, now: now.addingTimeInterval(7200)).accessTokenCurrent == false)
        try check(managed.ssoSessionCacheStatus(for: login, now: now) == AWSSSOSessionCacheStatus())
        try check(managed.ssoSessionCacheFile(for: source) == tokenFile && managed.ssoSessionCacheFile(for: login) == nil)
        let sandbox = base.appendingPathComponent("restart-sandbox")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try check(try managed.copySSOSessionCache(for: source, into: sandbox))
        try check(try FileManager.default.contentsOfDirectory(atPath: sandbox.path) == [tokenFile.lastPathComponent])
        try check(try Data(contentsOf: sandbox.appendingPathComponent(tokenFile.lastPathComponent)) == Data(contentsOf: tokenFile))
        try check((try FileManager.default.attributesOfItem(atPath: sandbox.appendingPathComponent(tokenFile.lastPathComponent).path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let sharedDirectory = base.appendingPathComponent("restart-shared")
        try FileManager.default.createDirectory(at: sharedDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try check(rejected { _ = try managed.copySSOSessionCache(for: source, into: sharedDirectory) })
        try managed.removeSSOSessionCache(for: source)
        try check(!FileManager.default.fileExists(atPath: tokenFile.path))
        try check(FileManager.default.fileExists(atPath: cachePath(legacy.ssoStartURL).path))
        try check(!managed.ssoSessionCacheStatus(for: source, now: now).present)
        try check(try managed.copySSOSessionCache(for: source, into: sandbox) == false)
        try managed.removeSSOSessionCache(for: source)
        metadata.removeValue(forKey: "refreshToken"); try saveMetadata()
        let withoutRefresh = managed.ssoSessionCacheStatus(for: source, now: now)
        try check(withoutRefresh.present && !withoutRefresh.hasRefreshToken && withoutRefresh.accessTokenCurrent)
        try check(rejected { try managed.removeSSOSessionCache(for: login) })

        // Duplicate auth fields, malformed descriptors, links and oversized input
        // are rejected using only disposable files.
        try write("[profile duplicate]\nsso_start_url = https://example.awsapps.com/start\nsso_start_url = https://second.invalid/start\n")
        try check(rejected { _ = try managed.discover() })
        var invalid = source; invalid.id = String(repeating: "0", count: 64)
        try check(rejected { _ = try managed.prepareBackingConfig(invalid) })
        invalid = source; invalid.name = "bad\n[profile injected]"
        try check(rejected { _ = try managed.prepareBackingConfig(invalid) })
        invalid = login; invalid.accountID = "999999999999"
        try check(rejected { _ = try managed.prepareBackingConfig(invalid) })
        try write(String(repeating: "#", count: 1_048_577))
        try check(rejected { _ = try managed.discover() })
        try FileManager.default.removeItem(at: config)
        let target = base.appendingPathComponent("symlink-target")
        try Data(original.utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: target)
        try check(rejected { _ = try managed.discover() })
        try check(rejected { _ = try managed.install(source, targetName: "workspace-shared", launcherPath: helper) })
        try check(try String(contentsOf: target, encoding: .utf8) == original)
        // An imported shared profile is usable but does not claim that this Mac
        // holds a source login. Appending/removing it preserves missing EOF EOL.
        let receiverRoot = base.appendingPathComponent("receiver")
        try FileManager.default.createDirectory(at: receiverRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let receiverConfig = receiverRoot.appendingPathComponent("config")
        let noEOL = "# No final newline\n[default]\nregion = us-west-2"
        try Data(noEOL.utf8).write(to: receiverConfig)
        let receiver = AWSProfileConfiguration(configURL: receiverConfig, root: receiverRoot.appendingPathComponent("managed"))
        let receiverInstall = try receiver.install(source, targetName: "workspace-shared", launcherPath: helper)
        let receiverBacking = try String(contentsOf: URL(fileURLWithPath: receiverInstall.backingConfigurationPath), encoding: .utf8)
        let importedSession = try receiver.resolvedSSOSessionName(for: source)!
        try check(receiverBacking.contains("[sso-session " + importedSession + "]") && !receiverBacking.contains("sso_session = work-session"))
        var sibling = source; sibling.accountID = "999999999999"; sibling.name = "other-role"
        sibling = AWSProfileDescriptor(name: sibling.name, kind: "sso", ssoStartURL: sibling.ssoStartURL, ssoRegion: sibling.ssoRegion, accountID: sibling.accountID, roleName: "Reader", ssoSessionName: sibling.ssoSessionName)
        try check(try receiver.resolvedSSOSessionName(for: sibling) == importedSession)
        var separate = source; separate.ssoSessionName = "separate-person"
        try check(try receiver.resolvedSSOSessionName(for: separate) != importedSession)
        try check(try receiver.discover().isEmpty)
        try receiver.restore(receiverInstall)
        try check(try String(contentsOf: receiverConfig, encoding: .utf8) == noEOL)
        let receiverBytes = try Data(contentsOf: receiverConfig)
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: receiverConfig.path)
        try check(rejected { _ = try receiver.discover() })
        try check(rejected { _ = try receiver.install(source, targetName: "workspace-shared", launcherPath: helper) })
        try check(try Data(contentsOf: receiverConfig) == receiverBytes)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiverConfig.path)
        let otherPortal = noEOL + "\n[sso-session work-session]\nsso_start_url = https://other.awsapps.com/start\nsso_region = us-east-1\n"
        try Data(otherPortal.utf8).write(to: receiverConfig)
        let collisionBacking = try receiver.prepareBackingConfig(source)
        let collisionText = try String(contentsOf: collisionBacking, encoding: .utf8)
        try check(collisionText.contains("sso_session = " + importedSession) && !collisionText.contains("other.awsapps.com"))
        let deliberatePrivateCollision = otherPortal + "[sso-session " + importedSession + "]\nsso_start_url = https://other.awsapps.com/start\nsso_region = us-east-1\n"
        try Data(deliberatePrivateCollision.utf8).write(to: receiverConfig)
        try check(rejected { _ = try receiver.prepareBackingConfig(source) })
        let lockedConfig = receiverRoot.appendingPathComponent("locked-config")
        try Data("[default]\nregion = us-east-1\n".utf8).write(to: lockedConfig)
        let locked = AWSProfileConfiguration(configURL: lockedConfig, root: receiverRoot.appendingPathComponent("locked-managed"))
        let lockPath = receiverRoot.appendingPathComponent(".terminaldb-aws-config.lock").path
        let lockFD = Darwin.open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw PeerFailure("The AWS lock fixture could not start.") }
        defer { Darwin.close(lockFD) }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw PeerFailure("The AWS lock fixture is unavailable.") }
        try check(rejected { _ = try locked.install(source, targetName: "workspace-shared", launcherPath: helper) })
        _ = flock(lockFD, LOCK_UN)
        try check(try String(contentsOf: lockedConfig, encoding: .utf8) == "[default]\nregion = us-east-1\n")
        let linkDirectory = base.appendingPathComponent("linked-config-directory")
        try FileManager.default.createSymbolicLink(at: linkDirectory, withDestinationURL: receiverRoot)
        let linked = AWSProfileConfiguration(configURL: linkDirectory.appendingPathComponent("locked-config"), root: base.appendingPathComponent("linked-managed"))
        try check(rejected { _ = try linked.discover() })
        let hardlink = receiverRoot.appendingPathComponent("hard-linked-config")
        try FileManager.default.linkItem(at: lockedConfig, to: hardlink)
        try check(rejected { _ = try locked.discover() })
        try check(rejected { _ = try locked.install(source, targetName: "workspace-shared", launcherPath: helper) })
        return count
    }
}
