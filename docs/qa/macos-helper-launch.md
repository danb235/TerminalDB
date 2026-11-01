# macOS helper launch regression

## Failure and correction

After a macOS upgrade, the installed 0.6.0 networking and session helpers were
registered with Launch Services as `com.terminaldb.app`. Opening TerminalDB
activated the networking process instead of starting the GUI. The networking
process was healthy, so repeatedly force quitting the app's apparent process
could also cause launchd to restart it. At diagnosis the session host was
responsive and held no sessions; the two previously approved devices remained
in its trust store.

The helpers now live in separate self-contained bundles under `Contents/Helpers`
with their own metadata before AppKit initializes. They have distinct identifiers,
bundle locations and background/accessory roles. The GUI alone owns
`com.terminaldb.app`. Development bundles also start those actual executables
instead of starting copies of the GUI with helper flags. Execution services
continue sharing the existing `com.terminaldb.app` preferences explicitly.
There is no change to device keys, paired trust, networking or terminal protocol.
The build uses the selected Apple compiler through `xcrun`, avoiding an unrelated
Homebrew compiler's stale SDK path after the operating system upgrade.

## Automated plan

- Run native surface, protocol, persistent host, product, signature, icon,
  secret-scan and Claude hook regression checks.
- Exercise the actual bundled helper executables in the persistent host tests.
  Inspect only those process IDs in Launch Services and require their separate
  identities. Do not print the inventory of unrelated apps.
- Run the real-agent LAN pairing/session/revocation tests using the bundled
  helpers and disposable, ephemeral device identities.
- Build both architectures and verify the final signed bundle.

## Visible plan

Use an installed disposable QA bundle and synthetic private work, preserving
production sessions and configuration. Never record terminal contents or keys.

1. Launch from Finder while both helpers are running. Confirm one visible app
   window and This Mac; open another local tab with the normal + control.
2. Type a synthetic shell command and verify its result without recording the
   terminal's contents. Open About and confirm the candidate version.
3. Quit through TerminalDB's menu. Confirm the GUI exits and both helpers and
   the original shell remain alive. Open through Finder and resume that shell.
4. Force quit the GUI with macOS Force Quit and reopen normally. Check shell
   survival on the final canonical installation, whose helpers are managed by
   launchd independently of the GUI. Development helpers share the launching
   GUI's process coalition and can be terminated by macOS with that coalition.
5. On the final installed canonical app, confirm About 0.6.1, a working local
   terminal, two retained pairings and normal quit/reopen while helpers run.

The earlier three-Mac pairing, security, LAN/VPN and sleep/wake acceptance record
remains in `docs/native-peer-qa.md`. This focused packaging fix does not claim a
new physical run of those network scenarios.

## Outcomes

- On macOS 27.2, the installed disposable candidate opens a visible local
  terminal, + opens This Mac, and keyboard input executes on its session host.
- About displays 0.6.1. Normal Quit leaves the two helpers alive; reopening and
  Resume Session return to the exact original shell, verified by synthetic PID
  markers without recording terminal contents.
- macOS Force Quit exits the test interface. Its directly spawned development
  helpers also exit with that process coalition. Normal reopening succeeds.
  Final managed-service Force Quit/session survival and canonical About checks
  are recorded in the PR handoff after installing the merged primary branch.
- Automated checks pass: 92 surface, 86 protocol/security, 23 persistent-helper
  and 20 real-agent integration checks, plus product, background-tab, signature,
  icon, secret-scan and Claude hooks. The persistent-helper checks inspect both
  running helper bundle identifiers and their separate bundle locations.
