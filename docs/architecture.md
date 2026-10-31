# Architecture

TerminalDB is an AppKit application built with clang and a pinned Swift package.
SwiftTerm provides terminal emulation; Apple SwiftNIO, NIOSSL and Swift
Certificates provide peer networking and TLS.
The repository also contains a static marketing site and GitHub Actions release
automation.

## Native application

`src/main.m` owns native application lifecycle, menus, windows and the legacy
product adapters. `TerminalPeerIntegration` exposes host-side services to native
clients. The per-user session helper owns PTYs, shells, shell integration and the
authoritative SwiftTerm engine; the peer helper owns authenticated connectivity.
See [peer architecture](remote-architecture.md) for protocol and trust details.

Supporting components separate the main product concerns:

| Component | Responsibility |
| --- | --- |
| `TerminalLedger` | Structured command records and searchable local history |
| `TerminalPermissions` | Risk classification and execution approvals |
| `TerminalInspector` | Restricted read only command inspection |
| `TerminalProduct` | Workspaces, playbooks, monitors, environments, and settings |
| `ClaudeProfile` | Isolated Claude subscription profiles and usage |
| `ClaudeAPI` | Anthropic API key configuration, model discovery, and requests |
| `ClaudeAssistantView` | Chat transcript, context chips, command and patch actions |
| `ClaudeStatusBar` | Active account and usage status |
| `TerminalTheme` | Application colors, fonts, and Claude Code theme adaptation |

Each persistent session owns a PTY and a `zsh` process in the session helper.
Tabs attach as viewers; closing one does not end its session. Temporary shell hooks mark
command boundaries, current directories, titles, exit codes, and Claude Code
state. TerminalDB turns those lifecycle events into command records.

## Data flow

1. The user enters a command in the terminal.
2. The shell hook records the command boundary and working directory.
3. PTY output is rendered and accumulated for the active block.
4. The exit hook supplies status and timing.
5. The ledger redacts known secret patterns and stores the structured record
   unless Private Session is active.
6. The user can attach explicit blocks or selections to AI chat.
7. Proposed commands pass through the permission center before execution.

## Storage

Application data lives under the user account:

- TerminalDB preferences for UI state and API provider configuration
- Application Support for command history, playbooks, workspaces, monitors, and
  Claude profile metadata
- isolated Claude configuration directories and Claude Code credentials for
  subscription profiles

Private Session stops new command records and workspace chat from being saved.
It does not erase existing history or prevent child commands from writing their
own files.

## Network boundaries

The terminal itself does not send telemetry. Network access occurs when the user
uses:

- Bonjour LAN discovery and connections to explicitly paired Macs
- internal LAN/VPN addresses, network changes and sleep/wake recovery
- Anthropic API chat and model discovery
- a Claude Code subscription session
- Claude usage refresh
- GitHub release update checks
- links opened explicitly from the application

## Marketing and releases

`marketing/` is a separate static site. `.github/workflows/site-ci.yml`
validates and deploys it independently from the app.

`.github/workflows/release.yml` validates version tags, runs native tests,
builds a universal bundle, applies the configured stable identity, publishes
SHA 256 checksums, and creates a GitHub release.

## Persistent native workstation sessions

The session and peer helpers replace GUI-owned live sessions and the cloud
remote implementation. See [peer architecture](remote-architecture.md) for the
current process boundaries, transport, authority and recovery contract.
