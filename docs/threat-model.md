# Threat model

The execution workstation, logged-in macOS user and approved peer devices are
trusted. A paired Mac has user-level terminal authority. The LAN, internet,
Bonjour names, saved addresses and forwarding intermediaries are not trusted
for endpoint identity or terminal confidentiality. The operating system,
Keychain, Secure Enclave, SwiftTerm and pinned TLS/certificate dependencies are
part of the trusted implementation.

See [native security](remote-security.md) for authentication, revocation,
forwarding, resource bounds, controller fencing and credential residency, and
[architecture](remote-architecture.md) for protocol limits. These are design
properties to test, not an assertion of perfect security.

Terminal output, repository text, assistant responses and update metadata are
untrusted. Existing command review, constrained inspections, patch review,
private-history handling, redaction and update validation remain required.
Compromised Macs, malicious explicitly approved peers, root access, shoulder
surfing and commands deliberately exporting secrets remain outside protection.
Revocation cannot reverse prior access or remove copied data. Full shell
access itself permits user-level changes, process creation and network access.

No vendor connectivity service holds terminal data or authentication accounts.
Claude and update requests remain separately enabled external features.
