# Paired workstation operations

## Setup

Install TerminalDB on each Mac and keep its user logged in, awake and powered on.
Allow TerminalDB background activity in System Settings → General → Login Items
& Extensions, and Local Network access in Privacy & Security when requested.
Open Paired Workstations on both Macs on the same LAN. Open pairing, select the
nearby Mac, compare complete fingerprints, and approve on both screens.

Use Shell → New Tab to choose This Mac or a paired workstation and then a new or
existing session. New windows default to This Mac; tabs and splits inherit their
workstation. Closing a tab detaches it; End Session stops its shell and work.
Use Take Control to transfer typing, sizing and session changes between viewers.

## LAN and VPN access

When away, connect your existing VPN to the LAN before opening a workstation.
TerminalDB does not configure the VPN or router and needs no public terminal port.
Pair the Macs initially on the same LAN; VPN membership alone does not grant trust.

Bonjour discovery may not cross routed VPNs. In Paired Workstations, select the
paired Mac, enter its internal IP address or internal DNS name in the LAN/VPN
address field, and click Save Address. Test Connection checks that exact saved
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

## Legacy cloud retirement

Do not treat source removal as deployed-resource deletion. First inventory the
dedicated stacks and retained resources using authorized operator credentials.
After native replacement passes acceptance QA, remove only TerminalDB remote
stacks, retained remote storage, cloud users, deployment credentials and remote
application/authentication DNS records. Preserve marketing/download DNS, updater,
GitHub releases, Claude integrations and shared infrastructure.

The October 2026 inventory found TerminalDBRemote-dev in us-west-2 (78 resources)
and TerminalDBRemote-dev-Edge in us-east-1 (5 resources). Resource identifiers are
kept in an operator-only inventory outside Git. Retirement is pending acceptance
QA. Cloudflare remote DNS removal also requires valid DNS-edit authorization.
No stack or DNS deletion is implied by this document.
