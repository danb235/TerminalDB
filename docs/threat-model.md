# Threat model

TerminalDB combines a terminal, persistent history, AI services, credential
selection, and command execution. This document defines the current trust
boundaries and limitations.

## Assets

- shell commands, output, paths, hosts, and timestamps
- local files exposed through explicit inspection or project tools
- Anthropic API keys
- Claude subscription profiles and credentials
- execution approvals and saved permissions
- update artifacts and the application bundle

## Trust assumptions

TerminalDB assumes the signed in macOS user controls the machine. A process
running as that user may be able to read preferences, application support data,
terminal memory, or the clipboard. TerminalDB does not protect against a
compromised operating system, administrator, shell startup file, or child
process.

Terminal output, repository files, AI responses, release metadata, and remote
hosts are untrusted input.

## Main threats and controls

### Accidental or coerced command execution

AI generated commands are shown with Paste and Run actions. Paste inserts text
without pressing Enter. Run uses risk classification, displays directory and
environment context, and requires stronger confirmation for writes, deletion,
`sudo`, remote or production targets, and unknown commands.

### Excessive AI context

The assistant receives a bounded terminal snapshot plus visible context chips.
Attached blocks and selections are explicit. Terminal content is described to
the model as untrusted reference data.

### Read only inspection escape

Inspection commands use a restricted allowlist and run within the selected
directory. Validation blocks shell chaining, network tools, destructive flags,
unbounded reads, and symlink traversal outside the directory. Tests cover known
escape attempts. This is defense in depth, not a general purpose sandbox.

### Secret persistence

Command records are redacted before storage using known secret patterns.
Private Session disables new persisted records. Redaction cannot recognize every
secret format, so users should avoid printing credentials and should clear
affected history if exposure occurs.

The Anthropic API key is stored in preferences to avoid repeated Keychain
authorization prompts in development builds. It is masked in the UI and never
intentionally added to command history. Any process that can read the user's
preferences may recover it.

### Profile crossover

Each Claude subscription profile has an isolated configuration directory and
Claude Code credential. Selecting a different profile starts a fresh assistant
conversation for that tab. Other tabs keep their assigned profile.

### Update substitution

Release artifacts are produced by GitHub Actions, checksummed, and signed with a
stable project identity when the release secret is configured. The updater must
verify the checksum, bundle identifier, version, architectures, and code
signature before replacement. The current project does not use Apple
notarization.

### Remote account takeover and recovery

Anonymous one-time links remain possession capabilities scoped to one terminal
session. Account signup additionally requires a short-lived grant signed by a
Mac's non-exportable key; a Cognito pre-signup trigger consumes the grant once.
The backend derives tenant identity only from a verified Cognito `sub` and
never from client-supplied IDs. Terminal payloads remain end-to-end encrypted
with separate Mac/browser keys.

There is intentionally no email or SMS recovery channel. Password changes and
desktop account deletion require an enrolled Mac request plus Touch ID or the
Mac login password. A password change revokes account controllers and
pre-change API tokens, but it does not remove a registered TOTP secret or
provide an alternate factor. A user who loses every authenticator copy cannot
self-recover; Cognito exposes no safe administrator operation for deleting a
user's TOTP secret. A compromised macOS user account is already in the trust
boundary and can manage
the TerminalDB account, matching its ability to access the local terminal
sessions.

## Privacy controls

- no analytics or crash reporting in the current build
- local command history
- configurable retention and history clearing
- Private Session for nonpersistent work
- explicit AI context attachments
- separate API and subscription provider configuration

## Out of scope

- malware or an administrator on the local Mac
- secrets deliberately typed into a remote host or third party program
- actions performed by commands after the user approves them
- security guarantees from Anthropic, GitHub, Cloudflare, or a remote shell
- Apple notarization until the project has an Apple Developer Program identity
