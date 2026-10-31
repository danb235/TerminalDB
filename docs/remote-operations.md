# Paired workstation operations

## Setup

Install TerminalDB on each Mac and keep its user logged in, awake and powered on.
Allow TerminalDB background activity in System Settings → General → Login Items
& Extensions, and Local Network access in Privacy & Security when requested.
Open Workstations → Manage Macs → Add Mac on both Macs on the same LAN. Select
the nearby Mac, compare both complete fingerprints, and approve on both screens.
Cancel if either fingerprint differs. Names are hints; keys establish trust.

Use ⌘T or + to open a terminal on This Mac immediately. New windows and private
sessions also use This Mac. In the toolbar workstation menu, choose New Terminal
on [Mac] to work elsewhere, or Resume Session to reopen existing work. The
hosting Mac appears first in each tab and in the toolbar. Splits inherit their
parent pane’s Mac. Opening a workspace preserves the current layout in another
window. Closing a tab detaches it; End Session stops its shell and work.
Use Take Control to transfer typing, sizing and session changes between viewers.

## LAN and VPN access

When away, connect your existing VPN to the LAN before opening a workstation.
TerminalDB does not configure the VPN or router and needs no public terminal port.
Pair the Macs initially on the same LAN; VPN membership alone does not grant trust.

Bonjour discovery may not cross routed VPNs. In Workstations → Manage Macs, select the
paired Mac and open Connection. Enter its internal IP address or internal DNS
name and click Save & Test. This checks that exact saved
address and verifies the pinned key. Leave the field empty and save to remove a
manual override. Discovered LAN addresses remain available independently.

Use a stable internal address or internal DNS name. Supported networks include
RFC 1918 IPv4, IPv6 ULA/link-local and shared VPN space (100.64.0.0/10). Public
addresses are rejected; listeners do not bind public interfaces. The VPN must
route the execution Mac's private subnet and, for internal DNS names, provide
working internal DNS. Avoid overlapping home/remote LAN subnets in VPN routing.
TerminalDB never relays traffic through another workstation. Each selected Mac
is reached directly over the current LAN or VPN route.

Trusted LAN access works without internet. Keep the execution Mac powered on,
awake and logged in. Closing the viewing laptop disconnects its views; waking it
and restoring LAN/VPN connectivity reattaches to the same shell. TerminalDB does
not wake a sleeping execution Mac or move its work elsewhere.

## Recovery

Direct LAN or LAN / VPN identifies a direct authenticated connection. Reconnecting
keeps work on its original Mac. Check power, sleep, login state, network permission,
background activity, the saved internal address and VPN routing. Wake recovery establishes
a new connection; it does not restart a shell elsewhere. If input delivery is
uncertain, inspect the terminal and acknowledge the warning before continuing.
It will not be repeated automatically.

For a background-service diagnostic, run
`/Applications/TerminalDB.app/Contents/MacOS/TerminalDB --peer-service-status`.
It reports each helper's macOS registration status without accessing device keys,
terminal contents or credentials. An installed helper can initially report
"not found"; opening the app registers it through Service Management.

Unavailable saved sessions remain reconnectable. An ended session must be
replaced explicitly with New Terminal. A session-host failure, reboot or logout
ends sessions. Restarting only the peer agent preserves sessions. Preserve active
legacy sessions before updating the old GUI-owned PTY implementation.

Removing a Mac immediately blocks it here. The default applies to This Mac only;
select the optional checkbox to request removal from other paired Macs. Hosts
that cannot be reached remain visibly pending and can be retried. To pair again,
remove the old pairing on both Macs first.

## Legacy cloud retirement

Do not treat source removal as deployed-resource deletion. First inventory the
dedicated stacks and retained resources using authorized operator credentials.
After native replacement passes acceptance QA, remove only TerminalDB remote
stacks, retained remote storage, cloud users, deployment credentials and remote
application/authentication DNS records. Preserve marketing/download DNS, updater,
GitHub releases, Claude integrations and shared infrastructure.

The October 2026 inventory found TerminalDBRemote-dev in us-west-2 (78 resources)
and TerminalDBRemote-dev-Edge in us-east-1 (5 resources). Resource identifiers are
kept in an operator-only inventory outside Git. The native replacement passed acceptance and 0.6.0 was installed on all three
workstations. The [handoff record](https://github.com/danb235/TerminalDB/pull/57)
tracks the dedicated stacks' retirement and remaining resources separately from
source removal. Cloudflare remote DNS cleanup is explicitly deferred by the user.
No DNS change is implied by this runbook.
