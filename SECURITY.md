# Security Policy

TerminalDB handles shell commands, command output, filesystem paths, AI
credentials, and permission decisions. Security reports are treated as a high
priority.

## Supported versions

TerminalDB is currently pre release software. Security fixes are made on the
latest release line and on `main`. Older prereleases are not supported.

## Reporting a vulnerability

Use GitHub private vulnerability reporting for
[danb235/TerminalDB](https://github.com/danb235/TerminalDB/security/advisories/new)
when it is available. If private reporting is unavailable, open a minimal issue
that asks the maintainer for a private contact channel. Do not include exploit
details, credentials, terminal output, or private paths in a public issue.

Please include:

- the affected version and macOS version
- a concise description of the impact
- reproducible steps using synthetic data
- whether command execution or credentials are involved
- any proposed mitigation

You should receive an acknowledgement within seven days. A fix timeline depends
on severity and reproducibility.

## Sensitive areas

Reports are especially useful for:

- commands running without the expected confirmation
- read only inspection escaping the selected directory
- secret redaction failures
- command history leaking across private sessions or profiles
- Claude subscription credentials crossing profile boundaries
- API keys appearing in logs, screenshots, history, or Git
- update downloads accepting the wrong bundle or checksum
- symlink, archive, or path traversal issues

## Current security posture

TerminalDB is open source and local first, but it is not a security boundary.
The current prerelease is not notarized. The Anthropic API key is stored in
TerminalDB preferences so development builds do not repeatedly prompt for
Keychain access. It is masked in the UI, excluded from command history, and
covered by repository secret scanning, but a user or process that can read the
macOS account preferences can recover it.

Claude subscription profiles use isolated configuration directories and
credentials created by Claude Code. Terminal command history is stored locally.
Private Session prevents new command blocks and workspace chat from being
persisted.

See [docs/threat-model.md](docs/threat-model.md) for assumptions and known
limitations.
