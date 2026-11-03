# Native UX polish QA

Use the installed application and normal native menus, buttons and fields.
Use disposable identities and synthetic accounts/profiles for sharing tests;
never capture terminal output, fingerprints, tokens or authorization URLs.
Do not stop active user commands or alter existing pairings to prepare QA.

## Terminal and workstation flow

- Launch into a local terminal without a chooser or empty command panel. Plus
  and Command-T create a local tab, including from a remote tab. Splits retain
  their parent execution workstation.
- Open a new terminal on another Mac from the workstation menu. Open Macs &
  Sessions, choose an existing session, and verify its shell stays on its host.
  An empty Mac offers New Terminal in the same picker.
- Confirm host context on remote tabs, account selection, history and tools.
  A command's environment classification must not imply local execution.
- Close and reopen a view without ending its shell. End Session is explicit.
- A sole controller has no disabled control button. A second viewer can take
  control using the visible contextual action. Input review is an explicit
  acknowledgment; no terminal input is replayed.

## Pairing and recovery

- Add Mac is directly accessible. Only eligible, unpaired, nonlocal candidates
  appear. QA services stay separate from normal installed discovery.
- Discovery updates preserve selection. Same-named devices with distinct
  identities remain distinguishable; names and public advertisements do not
  authorize access.
- Exercise opening, searching, connecting, full-fingerprint comparison on both
  Macs, waiting for the named counterpart, success and Open Terminal.
- Timeout replaces the list and fingerprints with one recovery state. Retry
  cannot inherit stale callbacks, selections or approvals from the old attempt.
- Cancel, reject mismatched fingerprints, deny an unpaired client and revoke a
  disposable pairing. Verify that future access is denied.
- Cover interface exits, helper restarts, sleeping/offline hosts, offline LAN,
  saved internal addresses and VPN disconnect/reconnect where available.
  Keep work on its original host and report unavailable physical cases pending.

## Accounts and generic AWS profiles

- The account control opens a compact picker scoped to this tab's Mac.
  Successful selection returns to typing. A rejected selection stays honest;
  a busy session offers a new tab on the same workstation.
- Management uses aligned compact rows and preserves focus, scroll, expanded
  details and row identity during background refreshes. Only relevant controls
  are clickable in the footer; paste receipts never overlap other status text.
- Add Claude Account follows the same flow with one or many Macs. Sharing
  remains independently approved; changes autosave, including on close.
- Detect arbitrary supported AWS profiles on each Mac. Cover local-only and
  shared profiles, matching identities under different aliases, identical names
  under different identities, multiple local aliases, conflicting local names,
  account/role selection, safe removal and offline addition/reconnection.
- Discovery does not modify AWS files or share credentials. Setup requires
  explicit conflict handling. AWS configures workstation profiles rather than
  implying a single AWS identity for the current terminal tab.

## Layout and accessibility

- Inspect 640, 900, 1280 and 1920 point window widths, split panes, long Mac and
  account names, one/many accounts, enlarged text and Increase Contrast.
- Verify headings, rows and action columns align; menus, tool panels and status
  controls do not clip. History and project tools retain all actions when narrow.
- Exercise keyboard-only navigation, Escape, Return, focus restoration and
  VoiceOver names. Loading and status changes must not move focused controls.

## Evidence

Record automated results separately from visible local/physical outcomes.
Record merged-primary installation, installed version/About, protected active
work and any pending physical/provider/network scenarios in the PR handoff.
No public release tag is part of this change.

## Executed for 0.6.5

Automated: the full local gate passed 96 terminal-surface checks, 390 native
peer/store/configuration checks, 23 persistent-session scenarios, native
product/interface tests (including 174 AWS geometry/action checks), code
signature, icon, privacy and shell-hook checks. Native-agent integration passed
31 peer/account and 19 AWS scenarios using synthetic credentials. Final build
and pull-request check results are recorded in the pull request.

Visible local QA used isolated installed apps with disposable identities and
synthetic accounts. Normal controls exercised the 180-second pairing timeout,
Search Again, private full-fingerprint comparison, approval in both apps,
Open Terminal, remote input and Enter, instant local new tabs, and interface
quits with persistent helpers. Two synthetic Claude sign-ins covered the compact
picker, acknowledged account selection, return to typing, and the busy-session
action that creates a tab on the same workstation while preserving the command.
Aligned active/inactive account actions, the expanded organization form and
visible project-tool actions were inspected in the native interface. Final-source
QA also placed a remote tab between two local tabs: the workstation menu and
session-browser default both followed the selected middle remote tab.

Visible physical QA paired two Macs through their native approval controls.
Each candidate's current device key was independently checked without exposing
pairing material. A remote terminal accepted input and Enter; a new tab stayed
local. The session browser attached an existing remote session in view-only mode,
and Take Control transferred control. Removing the disposable pairing immediately
removed the Mac and presented reconnect recovery while its host kept running.

AWS QA used arbitrary synthetic profiles on both physical Macs. Sign In completed
through the native button. Both sharing approvals saved automatically. A shared
profile with the same name but a different identity received a safe suggested
name and ran a command successfully, preserving the original profile. A matching
identity under another local name appeared in one row; installing it and adding
another alias preserved both working names. These were synthetic CLI responses,
not real AWS browser authorization. Real AWS configuration and production trust
were preserved.

Pending physical/provider scenarios for this UI pass: fingerprint mismatch,
unpaired denial, sleep/wake, disconnected-internet LAN, saved internal address
changes, VPN disconnect/reconnect, and real AWS/Claude browser authorization.
Automated coverage and earlier feature acceptance do not replace these cases.
