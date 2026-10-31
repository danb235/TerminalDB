# Native pairing and security

An approved peer can operate terminals as the logged-in user on that Mac. Pair
only devices you control. Security depends on fingerprint verification, correct
implementation and uncompromised Macs; TerminalDB makes no absolute security
claim.

## Trust

Open pairing on both Macs on the same LAN. Compare the full displayed device
fingerprints independently on both screens before approving both. Nearby names,
IP addresses and Bonjour announcements are untrusted address hints. An unpaired
connection cannot enumerate sessions or perform terminal operations. Existing
cloud enrollment never establishes native trust.

Each installation keeps a persistent P-256 device identity in Keychain. Secure Enclave keys are
non-exportable in hardware; Macs without one use a software Keychain key
imported with non-exportability enforced by macOS. TLS 1.3 provides mutual authentication and
forward secrecy. Pinned public keys are verified by SwiftNIO SSL; certificate
signing uses maintained Swift Certificates and Apple's Keychain APIs. TerminalDB
does not implement cryptographic primitives or accept replayable early data.
A replacement key requires fresh pairing; certificate renewal preserves the pin.

Removing a pairing closes that device's connections immediately on this Mac.
The native removal dialog can apply a separate removal to each other paired
Mac. Unreachable Macs remain explicitly pending; retry once they are reachable.
Trust is never granted transitively. Removing this Mac on the removed device is
a separate action. A compromised approved peer already has user-level shell
access; revocation cannot undo work it performed before removal.

## Network exposure

LAN pairing is time limited. Terminal listeners bind only assigned internal
addresses: RFC 1918 IPv4, link-local, IPv6 ULA and shared VPN space, plus loopback.
Globally routable interfaces and wildcard binds are excluded. Remote sources and
resolved destination addresses must pass the private-address policy. DNS is
resolved off the main thread; connection uses the exact validated sockaddr, so
there is no second DNS lookup that could rebind to a public destination. Internal
DNS names are supported for routed VPNs. VPN client routing and private address
assignment must be configured in the VPN itself.

Public endpoints, endpoint announcements, NAT traversal and forwarding are removed.
No peer can request a tunnel, proxy or public reachability probe. Legacy internet
and forwarding settings are dropped while independently approved keys remain.
Handshake admission, DNS work, frame size, logical messages, receipts and queued
deliveries are bounded. LAN/VPN transport still requires pinned mutual TLS; access
to the network alone never grants terminal authority.

Typing, resizing, Claude operations and mutations require the current controller
generation. Read-only viewers cannot run arbitrary project inspections. Expired
input is rejected; missing acknowledgements are shown as uncertain without
resending commands. A prepared command approval is one use, expires, and binds
the user, session, directory and control generation.

Host credentials remain on their workstation. Profile names and usage summaries
can appear remotely, but API keys and Claude credential files are not exported.
Entering a new API key through settings sends it only to the selected host over
the authenticated connection. Appearance and keyboard preferences remain local.
Terminal output, repository text and AI suggestions are untrusted content.

The app's existing Anthropic API key storage remains in host preferences.
Private Session suppresses persisted history; it does not prevent explicitly
approved viewers from seeing the live session. App update and separately enabled
Claude activity can contact their respective services and are outside terminal
connectivity. The marketing/download site remains independent.
