# Private workstation acceptance plan and evidence

## Current scope

Terminal connectivity is LAN/VPN only. Public endpoints, port forwarding,
third-Mac forwarding and NAT traversal were removed at the user's request.
The unsaved UniFi drafts were discarded; no TerminalDB router rules were saved.
Existing independent device approvals remain valid. The old unusable VPN profile
is excluded from testing; the user has configured a WireGuard tunnel instead.

## Visible acceptance plan

Use installed native bundles, disposable sessions and synthetic text. Preserve
active legacy work. Never record terminal contents, fingerprints, credentials,
pairing material or provider configuration in screenshots, logs or public reports.

1. Pair through Workstations → Manage Macs → Add Mac on both physical Macs, compare
   full fingerprints, cancel a mismatch, approve both and verify unapproved denial.
   Use the third Mac to check that trust is not inherited through another Mac.
2. Open immediate local tabs with + and ⌘T, including from remote tabs. Use the
   workstation menu for direct remote creation and Resume Session for existing
   work. Verify host-first labels, active split context, independent selected tabs,
   inherited splits, local private sessions/windows, workspace order/restore and
   unavailable session placeholders without creating replacement shells.
3. Exercise real keyboard punctuation, Unicode, large paste, Ctrl-C, scrollback
   and a full-screen program. Share views, take control and resize; verify passive
   input, stale controllers and passive geometry cannot change the host.
4. Exercise remote history/bookmarks, private sessions, playbooks, monitors,
   workspaces, project previews/assistant context, profiles/models, inspections,
   command review and patch apply/revert. Confirm execution and state stay on the
   selected Mac and appearance stays on the viewing Mac.
5. Close tabs and quit the interface during running work. Reattach to the same
   shell. Restart networking without restarting the session host. End Session
   must explicitly stop work.
6. Save an internal address through the normal settings field, test it and try a
   rejected public address. Confirm the public endpoint and forwarding controls
   are absent. Test a changed internal address and practical recovery instructions.
7. Test LAN with internet unavailable. Activate the user's WireGuard tunnel from
   another network, attach using an internal address, interrupt/restore the VPN,
   close/open the viewing laptop's lid and confirm the original shell continues.
   Bonjour crossing the VPN is not required. The execution Mac must stay awake.
8. Revoke a device, check immediate disconnect/denial, apply independent removals
   to other Macs and check pending status when a host is unreachable.
9. Audit connection destinations and private listener bindings, excluding
   separately enabled Claude/updater traffic. Measure LAN keypress-to-rendered
   frame latency on idle test Macs, targeting p95 below 50 ms. Retain timing only.
10. Complete checks, merge the feature PR, update the primary checkout, install
    with make install and verify installed About 0.6.0. Retire only inventoried
    TerminalDB cloud resources after acceptance. Publish no release tag.

## Automated evidence

The LAN/VPN implementation passed 92 terminal-surface checks, 86 native protocol
and security checks, and 21 persistent-session integration checks, plus product,
background-tab, signature, icon, secret and Claude shell-hook checks. An additional 20 real-agent checks passed for pairing, internal addresses, public
address/obsolete-operation rejection, remote sessions and revocation. Both Mac
architectures build successfully. Network restoration notifies disconnected
views immediately; unauthenticated handshakes expire and cannot exceed admission
limits.

The native client also drains queued typing after 256 unrelated requests fill
and then release its callback window. Ordinary input batches on the next event
loop turn; only backpressure uses a short retry timer.

Current tests cover framing/fragment assembly, budgets, exact byte ordering,
controller fencing, receipt namespaces, expired input and no replay, mutual pinned
TLS, wrong-key rejection, revocation, repeated direct reconnection, private IPv4
and IPv6 boundaries, public-address rejection, DNS answer filtering and migration
that discards obsolete internet settings while retaining paired keys. A startup
race was fixed by publishing local sockets only after chmod and listen succeed.

Persistent-helper tests use real PTYs: duplicate create receipts, stale/expired
input, passive inspection/reveal denial, takeover, shell identity, interface
exits, networking restarts and host-owned product actions. SwiftTerm tests cover
single-authority query replies, snapshots, Unicode, query/mouse behavior and paste
backpressure. Applicable former JavaScript fault contracts were ported; obsolete
Cognito, browser relay and AWS rotation contracts were removed.

A prior optional Keychain pass verified stable hardware identity and a
non-exportable software fallback signing key. It predates the LAN/VPN transport
simplification; final installed identity and trust continuity remain acceptance
checks. Automated counts do not substitute for the physical scenarios above.

## Visible outcomes already observed

- All three physical Macs independently approved their bilateral pairings through
  native controls. Cancelled confirmation and expired pairing were exercised.
  Access to the mini was denied before the MBP paired with it independently.
- Direct LAN new/existing sessions, independent selected tabs, shared viewers,
  takeover, passive input/resize fencing and controller sizing passed.
- In the earlier interface, tabs/splits inherited the mini and project directory.
  New windows used This Mac. That tab default is superseded by the local-first
  simplification below. Private commands on the mini stayed out of persisted history.
  Workspace restore reattaches the existing shells and split layout.
- Remote bookmarks, reviewed playbook execution, monitor display, workspace save
  and the mini's synthetic project preview passed through normal controls.
- Physical key events preserve punctuation. An 84,000-byte Unicode paste arrives
  exactly. Ctrl-C recovers and a full-screen Unicode program returns to the shell.
- Tab close, interface quit and networking-helper restart preserve running work
  and shell identity. End Session stops the shell.
- Pending Local Network permission produced Unreachable; native approval restored
  Direct LAN with the same key. Firewall/Accessibility approvals were exercised.
- The MBP runs an installed candidate with both helpers enabled and running under
  macOS Service Management. Its Keychain approval is complete. The previous app
  and local data are backed up locally. Fresh-service registration was corrected
  for the initial macOS "not found" state.
- Replacing the installed candidate exposed a stale enabled service registration.
  Recovery checks the lease and running processes before re-registering a stopped
  helper; a live session host is left running.
- Marketing navigation, FAQ and downloads passed in a visible browser at three
  viewport sizes. Updated LAN/VPN copy, navigation, FAQ toggles and download links
  passed at 1440, 768 and 390 pixels without horizontal overflow, script errors or
  contact with retired app/auth domains.
- The final LAN/VPN settings saved and tested a workstation's internal address,
  verified its pinned key, and rejected a public address through normal controls.
- With public internet requests blocked temporarily on the MBP, visible terminal
  input still reached its original execution Mac. The test firewall rules were
  removed and internet access verified afterward.
- The updated MBP interface read the execution Mac's synthetic project file and
  prepared assistant context through Ask AI. Native inline command review,
  patch permission review, apply and Revert Last AI Patch passed against that Mac's
  synthetic file. Markdown patches missing their final newline are normalized.
- A mixed-workstation layout saved through the MBP's native workspace controls
  contains absolute device references for both Macs and their existing sessions.
  Legacy empty references resolve relative to the workspace collection's host.
- Restoring that layout through the native controls reattached both existing
  sessions without creating extra shells. Reviewed input from the restored view
  still executed on the original workstation.
- Native End Session stopped a disposable shell. Restoring its saved workspace
  kept an ended-session placeholder without creating a replacement shell. Its
  control now reads Session Ended. Snapshot creation retains the attachment ID of
  unavailable panes; the later visible re-save pass preserved those references.
- The installed MBP candidate's normal About window reported 0.6.0.
- The actual WireGuard Home profile was activated temporarily. The MBP's native
  Test Connection verified the paired key at the tunnel's private address. With
  the direct LAN terminal address blocked, New Tab attached an existing session
  through that VPN address and showed LAN / VPN. Visible input executed there.
  Stopping the tunnel and restoring the LAN route reattached the same live shell;
  its background work completed. Temporary test rules and manual address were
  cleared, and WireGuard was returned to its original inactive state. Both Macs
  were physically on the home network; this does not prove outside-network access.
- TCP listener and destination audits of all three networking helpers found only
  private addresses. Claude, updater and the preserved legacy cloud agents were
  excluded from this networking-helper audit.
- The viewing Mac joined an iPhone hotspot and connected WireGuard Home. Its
  route to the mini used the VPN interface. The native tab showed LAN / VPN,
  accepted visible input on the original mini shell, and reattached after a
  deliberate tunnel disconnect/reconnect. The same shell and background task
  continued throughout; this is an actual outside-LAN pass.
- On the LAN, 80 physical key-event-to-captured-frame samples measured median
  39.2 ms, p95 44.3 ms and maximum 55.5 ms. The p95 target below 50 ms passed.
  ScreenCaptureKit inspected one synthetic background pixel in RAM and retained
  timing only. The measurement includes capture-callback delay. Earlier runs
  with heavy QA browser activity did not meet the target; the completed browser
  session was closed before this pass.

- After the viewing laptop actually slept and woke, its native view reattached to
  the same original mini shell. A bounded synthetic heartbeat on the mini kept
  progressing during the viewer's sleep with a maximum scheduling gap of 1.01 s.
  The viewer then returned to LAN Wi-Fi and WireGuard Home was left inactive.
- Native removal on the mini immediately disconnected the MBP and rejected its
  next connection before session inventory. Other bilateral trust stayed intact.
  The Macs then re-paired through normal controls with full fingerprint checks.
- A removal requested from the MBP while the primary was unreachable showed
  pending status. After restoring that path, Retry Pending Removals applied the
  independent removal on the primary. All three bilateral pairings were then
  restored through native verification. Temporary test firewall rules were removed.

## Local-first interface acceptance

The updated interface makes + and ⌘T immediate local actions, names the hosting
Mac first in tabs and the toolbar, offers direct remote creation from one menu,
and combines existing-session selection in one browser. Add Mac guides discovery,
full fingerprint comparison and bilateral approval in one sheet. Connection
addresses stay behind an optional Connection control. Removal defaults to this
Mac; propagation is an explicit checkbox. Saved workspaces open in a new window.
The mini’s visible native controls passed immediate local New Tab and +, local
private sessions opened from remote work, direct creation on another Mac, the
combined Resume Session browser, host-first title/toolbar labels, same-host splits,
Add Mac cancellation, optional Connection settings and default local removal.
Opening a saved layout created no extra shells. Saving it again from a live pane
retained the ordered references for every workstation/session, including the ended
pane. The updated panel showed a successful save on the named host and a rejected save
with a visible Take Control instruction after another viewer took control.
The final universal build’s guided sheet passed on the primary Mac and mini.
Both full displayed fingerprints matched the existing device identities. A
mismatched expected fingerprint prevented scripted approval; cancellation through
the normal button granted no access. Approving one side showed Waiting for Other
Mac and granted no trust. Approval on the second physical Mac completed both
pairings and closed both pairing windows. A new remote terminal accepted visible
input on the mini; its selected local tab stayed unchanged. The next + action
opened This Mac immediately. The management screen’s layout and contrast were
also visually inspected with terminal and pairing details excluded.

The real-agent tests additionally verify that the pairing-only discovery name is
withdrawn after pairing closes. Three simultaneous two-sided initiation rounds
converged on a single connection and still required independent approval by both
Macs. This prevents the two native screens from waiting on different requests.

Final primary/mini canonical installation and About verification remain in the
repository handoff. Original active legacy work on those Macs is still running;
private on-device backups of the original apps, saved settings and data are
complete. The MBP’s eight native shells had no foreground non-shell processes at
preflight. Replacing the old GUI-owned sessions requires finishing their work or
explicit authorization to stop them; stored-data backups cannot preserve running
processes. Cloud retirement, repository merge and final installation are pending.
Remote DNS cleanup is explicitly deferred by the user.
