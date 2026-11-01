# Native peer architecture

TerminalDB has one macOS application bundle and two per-user background helpers.
`TerminalDBSessionHost` owns persistent PTYs, shells, shell hooks, SwiftTerm state,
bounded scrollback, Claude credentials and execution-related product services.
`TerminalDBPeerAgent` owns Bonjour discovery and direct TLS connections over the LAN or VPN.
The interface uses the same typed session protocol for This Mac and paired Macs.
Restarting networking does not restart shells.

Each helper is a separately identified background app under
`Contents/Library/LoginItems`, registered through `SMAppService.loginItem`.
The interface alone owns the main app's bundle identity and appears in Force Quit.
Stopped legacy LaunchAgents are migrated using asynchronous unregistration;
a live legacy host retains its shells until it stops. Helper repair never
unregisters a process holding the session lease or waiting for Keychain approval.

The host uses SwiftTerm's UI-independent terminal engine. Native viewer renderers
suppress terminal-generated query replies; only the host answers the shell.
The existing product adapter supplies ledger, Claude, permission, patch, project,
playbook, monitor and workspace operations over the service interface. AppKit
presentation remains in the interface; some legacy product adapters still share
AppDelegate code with the host and are candidates for further separation.

## Connections and authority

Bonjour advertises an opaque device hint and protocol version. It does not grant
trust. An explicit three-minute LAN pairing window allows an untrusted device
only into the pairing protocol. Both users compare full fingerprints and approve
before either application grants session access. Trust is independent per Mac.

TLS 1.3 authenticates both device keys. The device identity uses Keychain signing,
Secure Enclave when available, Swift Certificates and SwiftNIO SSL/BoringSSL.
The pin is SHA-256 of the certificate public key. Certificates are renewed with
the same key. Changing keys requires pairing again. No early application data
or custom encryption handshake is used.

Connections use authenticated Bonjour address hints on the local LAN and saved
internal addresses or internal DNS names over the user's VPN. DNS answers are
checked once and the client connects to that exact private sockaddr; public
answers are rejected. Listeners bind only assigned private/link-local/loopback
addresses, never wildcard or globally routable interfaces. Accepted sources must
also be private. RFC 1918, IPv6 ULA/link-local and shared VPN address space are
supported. Private routing and DNS are the VPN's responsibility.

There are no public endpoints, router changes, NAT traversal, mesh routing,
forwarding, public rendezvous or vendor relay. Existing paired keys survive the
removal of legacy endpoint and forwarding settings. Closing the viewing laptop
or changing networks closes its old views, never the execution shell. Debounced
network notifications and wake recovery refresh private listeners/discovery and
reconnect using new connection generations. Saved internal addresses work without
Bonjour crossing the VPN. TetrisGO informed bounded queues and monotonic recovery,
not connectivity dependencies or execution migration.

## Session protocol

Session identifiers survive interface connections. Each viewing pane has an
independent client identifier. One principal holds the control lease. Takeover
increments a generation and fences old input, sizing and session mutations.
Attaching never changes the execution Mac's selected interface tab.

Messages use a four-byte big-endian length and JSON. Physical frames are at most
1 MiB; logical messages are at most 8 MiB and require ordered bounded fragments.
Transport queues and queued deliveries are bounded at 16 MiB. Slow readers are
disconnected. There are at most 32 incoming connections, including handshakes.
Local sockets require the same user and a private launch secret, with directory
mode 0700 and socket/state modes 0600. A compromised macOS user is outside this
boundary and can already run commands as that user.

Input has a contiguous sequence, a control generation and a short deadline in
the host's monotonic clock. The client derives a conservative clock estimate
from authenticated readiness; long initial transit can reject input early,
which is surfaced for review. Mutation receipts are bounded and namespaced by
principal. Unacknowledged commands are never automatically retried. Uncertain
input requires explicit review before more typing. Snapshot resynchronization
restores bounded terminal state after reconnect. Heartbeats and wake recovery
use new connection generations; execution remains on the original workstation.

Snapshots go only to the requesting view, while ordered PTY deltas continue to
all subscribed viewers. They preserve cells, attributes, bounded scrollback,
cursor and saved cursor, margins, character sets, application input modes and
an unfinished UTF-8/control prefix. The pinned SwiftTerm additions export this
state without changing its parser decisions. An unfinished control sequence
larger than 64 KiB defers resynchronization for at most two seconds and then
reports a failure; it never exports a truncated parser state. When reconnecting
inside the alternate screen, the view requests normal-buffer history again on
alternate-screen exit. Input stays disabled until snapshot delivery completes.

Rapid typing is coalesced for four milliseconds and sent in ordered 64 KiB
chunks. Client and PTY queues each retain at most 4 MiB. If a batch expires or is
rejected, the host blocks later input on that stream until the user reviews and
reconnects. This prevents a later Enter from executing a command with missing
text. Recovery markers store only workstation/session identifiers, never input.

Closing a view releases its lease and subscriptions. End Session explicitly
stops the shell. Quitting the interface leaves helpers alive. Sessions do not
survive host failure, logout or reboot. There is no file synchronization.
