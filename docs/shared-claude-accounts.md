# Shared Claude accounts

Accounts & Usage is a single account picker for this Mac and the Macs you have
chosen to sync. The heading names the workstation that runs the selected tab.
Choosing an account changes that tab's next Claude launch, not another tab or an
already running Claude process. Saved workspaces use the account identity; an
unavailable account leaves the selection empty rather than choosing another
subscription with the same name. New tabs still start on This Mac.

## Setup and everyday use

Pair your Macs normally. In Accounts & Usage → Sync Macs, select the Macs allowed
to receive your shared subscriptions and save. Enable this on both ends of each
connection. Pairing alone does not share accounts; adding a new paired Mac never
silently gives it your subscriptions. A synced Mac can pass received shared
accounts to its other explicitly approved account-sync Macs.

Use Share Sign-In on an existing account, or Add Subscription after enabling
sync. Claude Code opens its official browser sign-in on the Mac you are viewing.
Choose the displayed email and the intended organization. TerminalDB privately
captures the reusable token and saves it in that Mac's Keychain. Passwords and
ordinary rotating Claude login/refresh credentials are not copied. An existing
normal sign-in needs this one-time reusable sign-in before other Macs can use it.
Account email/organization labels are entered by the user, not identity claims
verified by TerminalDB against Anthropic.

On another workstation, open or resume a tab and choose Use on This Tab beside
the shared subscription. Accounts known only through another Mac's ordinary
local sign-in offer Make Available. A reusable account that has not arrived at
the execution workstation says Waiting for Sync. Usage details are under Usage
& Settings; unavailable or stale usage is not shown as current quota.

## Offline changes and recovery

- A new reusable sign-in works immediately on its originating Mac, including
  away from the LAN. It is saved before syncing and survives interface/helper
  restarts. It reaches approved Macs automatically after LAN or VPN returns.
- A receiving Mac keeps its own Keychain copy. The originating Mac can be asleep
  or offline when another Mac runs Claude. Disconnected Macs show their last
  known account inventory and cannot fetch an account they have never received.
- Renew Sign-In replaces an expired/revoked reusable sign-in once. Connected
  Macs receive the new revision; offline Macs receive it later. Tokens last up
  to one year; provider-side revocation can happen earlier. Restart Claude to
  use a renewed account. Claude.ai connectors still require normal local login.
- Remove under Usage & Settings removes the shared sign-in from the synced
  catalog. Offline removals propagate on reconnect. A concurrent renewal or
  delayed older copy cannot resurrect it. An explicit new sign-in after seeing
  the removal can restore it. Independent ordinary local sign-ins, history
  directories, and running Claude processes are preserved.
- Turning account sync off or unpairing a Mac stops future transfers. It cannot
  remotely erase an offline copy, revoke a provider token, or remove credentials
  already held by a running process. Revoke at the provider if access must end.
- Labels using the same normalized email and organization merge into one
  subscription. Different organizations remain separate. Concurrent renewals
  converge deterministically; concurrent removal wins.

## Storage, transport and authority

The session host owns a serial background account service; Keychain and code
signature work do not run on the terminal input queue. Only metadata enters
`Peers/shared-accounts.json`. Tokens are immutable Keychain items under
`com.terminaldb.claude.shared`, device-only and excluded from iCloud Keychain.
Secret-bearing bundles exist only in memory during pinned mutual TLS transfers
between Macs that opted in on both sides. There is no cloud account service.

Account revisions use bounded causal clocks and retained removal tombstones.
Metadata mutations use an interprocess file lock and atomic writes. A local
machine stamp rotates the writer after a copied-data migration; it is never
exported. Approved imports also restore supplied credentials whose unchanged
metadata already exists locally; metadata alone is not proof of a Keychain copy.
Normal sign-in directory snapshots use monotonically increasing
per-writer revisions, including empty snapshots for withdrawals. Replayed older
snapshots cannot restore withdrawn directory entries.

The network helper compares metadata digests every ten seconds while connected;
unchanged inventories need no Keychain read or credential transfer. Eight sync
connections, bounded deadlines, 128 account identities, bounded concurrent
versions and existing bounded framing/queues limit work. Sleep, route changes,
offline edits and network-helper restarts reuse the existing LAN/VPN recovery.
Execution stays on the selected workstation.

Sensitive local account operations require the private same-user socket and
kernel audit-token validation of the installed GUI/helper code. Remote session
clients cannot export credentials or start sign-in on a different Mac. Shared
token injection occurs only in a short-lived launcher that validates Anthropic's
signed native Claude Code executable, reads Keychain, and replaces itself with
that executable. Tokens are absent from command arguments, generated shell
scripts, general shell environments, terminal output, UI state and receipts.

QA-only stores require both ephemeral identity and explicit QA mode and reject
non-synthetic credentials. Automated tests use fake Claude Code within the
private fixture root. Tests never sign in to real subscriptions.

This feature assumes authorization to integrate reusable subscription tokens.
It does not imply provider endorsement. Security assumes correctly verified
pairing and uncompromised Macs and macOS user accounts. A trusted remote terminal
already grants powerful user-level access; no absolute security claim is made.
