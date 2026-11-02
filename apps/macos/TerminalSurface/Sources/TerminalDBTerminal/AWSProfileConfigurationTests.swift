import Foundation
import Darwin

enum AWSProfileConfigurationTests {
    static func run(root: URL) throws -> Int {
        let base = root.appendingPathComponent("aws-configuration")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let config = base.appendingPathComponent("config")
        let managed = AWSProfileConfiguration(configURL: config, root: base.appendingPathComponent("managed"))
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
        try check(try Data(contentsOf: config) == Data(original.utf8))
        let backing = try managed.prepareBackingConfig(source)
        let backingText = try String(contentsOf: backing, encoding: .utf8)
        try check(backingText.contains("[profile workspace]") && backingText.contains("[sso-session work-session]"))
        try check(!backingText.contains("endpoint_url") && !backingText.contains("ca_bundle") && !backingText.contains("plugins"))
        try check(!backingText.contains("static") && !backingText.contains("credential_process"))
        let aliasBacking = try managed.prepareBackingConfig(legacy)
        try check(aliasBacking != backing && (try String(contentsOf: backing, encoding: .utf8)) == backingText)
        try check(managed.loginArguments(for: source) == ["sso", "login", "--profile", "workspace"])
        try check(managed.loginArguments(for: login) == ["login", "--profile", "web-login"])
        try check(rejected { _ = try managed.install(source, targetName: "workspace", launcherPath: "/Applications/TerminalDB.app/helper") })
        try check(rejected { _ = try managed.install(source, targetName: "legacy", launcherPath: "/Applications/TerminalDB.app/helper", allowReplacingSource: true) })
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
        try check(receiverBacking.contains("[sso-session terminaldb-" + source.id + "]") && !receiverBacking.contains("sso_session = work-session"))
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
        try check(collisionText.contains("sso_session = terminaldb-" + source.id) && !collisionText.contains("other.awsapps.com"))
        let deliberatePrivateCollision = otherPortal + "[sso-session terminaldb-" + source.id + "]\nsso_start_url = https://other.awsapps.com/start\nsso_region = us-east-1\n"
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
