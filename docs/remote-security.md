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

LAN pairing is time limited. A configured internet listener accepts only pinned
peers outside a pairing window. Handshake admission, frame size, logical message
size, pending receipts, forwarding buffers and queued deliveries are bounded.
Forwarding requires an explicitly enabled paired Mac and a saved paired target;
it is not a general proxy. The destination authenticates the origin through an
additional end-to-end TLS connection. Gateways see addresses, timing and byte
counts but not terminal plaintext.

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
