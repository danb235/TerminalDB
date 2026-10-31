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

1. Pair through Paired Workstations: open pairing on both physical Macs, compare
   full fingerprints, cancel a mismatch, approve both and verify unapproved denial.
   Use the third Mac to check that trust is not inherited through another Mac.
2. Create and attach through New Tab. Verify workstation labels, independent
   selected tabs, inherited tabs/splits, This Mac windows, workspace restore and
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

The LAN/VPN implementation passed 92 terminal-surface checks, 81 native protocol
and security checks, and 20 persistent-session integration checks, plus product,
background-tab, signature, icon, secret and Claude shell-hook checks. An additional 14 real-agent checks passed for pairing, internal addresses, public
address/obsolete-operation rejection, remote sessions and revocation. Both Mac
architectures build successfully. Network restoration notifies disconnected
views immediately; unauthenticated handshakes expire and cannot exceed admission
limits.

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
- Tabs/splits inherit the mini and project directory. New windows use This Mac.
  Private commands execute on the mini without entering persisted history.
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

These outcomes include the earlier direct-LAN implementation. The final reduced
transport still needs a fresh installed pass for private bindings, settings,
network changes, remaining product actions, revocation, offline LAN, WireGuard
outside the LAN, lid recovery, latency and final About verification. Original
active legacy work on the primary Mac and mini remains running and protected.
Cloud retirement, repository merge and final installation are pending acceptance.
