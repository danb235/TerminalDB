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

## Internet access

At least one paired Mac must have a reachable configured endpoint. Forward TCP
49377 from the router to that Mac's fixed LAN address, or permit that port in its
IPv6 firewall. Restrict firewall exposure where practical. Save its public
address in Paired Workstations. Custom external ports can map to the normal
listener. Do not open a public pairing window or expose local IPC sockets.

Save This Address advertises this Mac's configured public endpoint to paired
Macs over authenticated connections. Save Address stores an address for the
selected paired Mac. Test From Selected Mac asks that paired Mac to connect
back and verify the actual pinned identity. Run it from a different network;
a LAN test cannot establish outside reachability, as the result explains. There is no third-party
connectivity test server.

Enable forwarding only on Macs that should carry encrypted traffic for other
paired Macs. The origin, destination and gateway need the appropriate independent
pairings. Multiple reachable Macs provide redundancy without a fixed coordinator.
LAN connections are tried first and remain usable without internet.

Some NAT and firewall combinations need a reachable intermediary. Here it must
be your paired Mac. TerminalDB does not automatically open router rules. If all
known public addresses change while every peer is unreachable, update an address
manually. This is the deliberate cost of avoiding public discovery infrastructure.
See [RFC 8656](https://www.rfc-editor.org/info/rfc8656/) for the general relay
connectivity problem; TerminalDB does not use TURN.

## Recovery

Direct LAN, Direct Internet and Via [Mac] identify the current path. Reconnecting
keeps work on its original Mac. Check power, sleep, login state, network permission,
background activity, saved endpoints and firewall rules. Wake recovery establishes
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
