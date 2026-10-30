# Native peer acceptance plan and evidence

## Visible acceptance plan

Use disposable sessions and synthetic text on installed native bundles. Preserve
all active legacy work. Never record terminal contents, private fingerprints,
credentials or pairing material in screenshots, logs or public reports.

1. On two physical Macs, open Paired Workstations using the normal toolbar/menu.
   Verify minimal discovery, closed pairing denial, open pairing on both Macs,
   fingerprint comparison and both approvals. Cancel a mismatch and expired pair.
2. Use Shell → New Tab to select a workstation, create a terminal and attach to
   an existing one. Verify host identity, independent selected tabs, inherited
   tabs/splits, This Mac windows and unavailable workspace placeholders.
3. Type Unicode, paste a large synthetic document, use Ctrl-C, scrollback and a
   full-screen program. Attach two viewers, transfer control, resize both, and
   confirm old controller input and sizing are rejected.
4. Exercise host history/bookmarks, private sessions, playbooks, monitors,
   workspace save/restore, project file previews, Claude profiles/provider/models,
   assistant inspection, command review and patch actions. Verify execution and
   saved state stay on the selected workstation; appearance remains local.
5. Close views and quit through the app menu. Reattach to the same shell and
   running work. Restart only networking and repeat. Explicitly End Session.
6. Disconnect internet while retaining LAN and repeat pairing/terminal actions.
   Test Local Network/background denial, sleep/offline states and visible recovery.
7. Use a paired Mac on another network to verify a configured public endpoint.
   Use a third physical Mac as an enabled gateway; force forwarding, remove a
   gateway, change an endpoint, and test alternate paths without shell migration.
8. Remove a peer, check immediate denial, apply removal to other Macs and verify
   unreachable hosts remain pending until retried. Confirm no unpaired inventory.
9. Observe configured-peer connections only, excluding separately enabled Claude
   and updater requests. Measure unloaded LAN input-to-display p95, target <50ms.
10. After merge and primary install, reopen /Applications/TerminalDB.app, verify
    About 0.6.0 and background-service operation, then retire dedicated cloud
    resources. Publish no release tag.

## Automated evidence

Current native pass: 92 terminal-surface checks, 32 peer checks and 18
persistent-session integration checks passed. An additional 12 checks exercise
real peer agents, Bonjour discovery, fingerprint mismatch, bilateral approval,
unpaired denial, remote PTYs, takeover, product services, reconnect and revocation.
The optional production-Keychain TLS pass completed 31 checks with a stable
hardware-backed identity and a non-exportable software fallback signing check. These pass along with native product self-tests,
background-tab QA, signature/icon/secret checks and Claude shell-hook checks. Native protocol tests cover framing,
Unicode, large-message assembly, malformed fragments, queue budgets, control
fencing, receipt namespaces, pinned mutual TLS, wrong-key rejection, revocation
and real nested TLS forwarding. Persistent-helper tests exercise real PTYs and
protected IPC, duplicate create receipts, stale/expired input, passive inspection
denial, takeover, shell identity, interface disconnects and peer-agent restarts. Busy-session account creation
leaves the active job and selected account intact; login is redirected into a
new tab on that workstation.
SwiftTerm tests cover single-authority query replies, headless parsing, snapshots,
selection, Unicode and large-paste backpressure. These supplement visible QA.

Applicable former JavaScript fault contracts were ported: duplicate mutation
receipts, stale generations, lost-ack uncertainty/no replay, bounded snapshot
assembly, ordered pipelined input and bounded reconnect generations. API Gateway
rotation, Cognito, browser viewport and cloud cost tests are obsolete and removed.
TCP/TLS provides ordered delivery; malformed native fragments fail closed.

## Visible evidence to date

- Local disposable native interface: opened Paired Workstations, opened the
  pairing window, toggled forwarding, and closed the panel through normal controls.
- Quit through TerminalDB → Quit: both background helpers remained running.
- New Tab: workstation and session sheets opened through the normal Shell menu;
  New Terminal and existing-session choices opened native tabs after the fallback fix.
- Normal Edit → Paste executes exact synthetic commands. Physical keyboard key
  events preserve letters, digits, hyphens, underscores and slashes. The separate
  automation method that sends Unicode strings as key events is unreliable;
  it is excluded from keyboard acceptance evidence.
- A full-screen synthetic Unicode program accepts a physical key and returns
  to its original shell. An 84,000-byte synthetic Unicode paste arrives exactly.
  Ctrl-C interrupts a running command and the same shell accepts the next one.
- History, Project Tools and Settings panels open through normal menus. Their
  full action workflows and remote execution checks remain pending.
- The original installed QA apps started with persistent Secure Enclave identities.
  The updated bundles require macOS approval to access those identities; this
  prompt is pending. No device key is replaced to bypass that approval.
- Marketing: normal navigation, FAQ toggles, current download links and three
  viewport sizes passed in a visible browser, with no script errors or requests to the retired
  app/auth domains. No cloud account bridge remains.
- Two/three physical Mac pairing, host tools, offline LAN, actual internet path,
  gateway failover, latency and final installed About checks remain pending.
- The mini is reachable for staging. The supplied MBP address is not reachable
  from this Mac or the mini; current address/Remote Login confirmation requested.

No visible physical/WAN pass or security certification is claimed by automated
counts. Cloud retirement and repository merge/install remain pending these gates.
