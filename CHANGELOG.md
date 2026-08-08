# Changelog

All notable changes to TerminalDB are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and TerminalDB uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-08-08

### Added

- TerminalDB Remote, with a mobile-first web app for securely viewing and
  controlling native terminal and Claude sessions from phones, tablets, and
  desktop browsers.
- Single-use guest links and QR pairing for temporary remote access without an
  account, including controller management and revocation from the Mac.
- Optional Cognito accounts with self-service signup, email verification,
  recovery, required TOTP, and automatic discovery of active sessions from
  every enrolled Mac.
- A multi-tenant, self-hostable AWS CDK stack with private web origins,
  CloudFront, API Gateway, Lambda, DynamoDB, Cognito, WAF, alarms, budgets, and
  deployment and operations guidance.
- Native remote bridge and agent processes with reconnect, snapshot resync,
  Claude account switching, usage refresh, and encrypted controller messaging.

### Changed

- Remote terminal input now renders optimistically and reconciles ordered
  acknowledgements, making typing feel immediate while preserving exact PTY
  input order.
- Account enrollment is additive: account-owned Macs can still create the same
  session-scoped guest links for convenient one-off access.
- The project is organized as a macOS, web, infrastructure, protocol, design
  system, and test-harness monorepo with dedicated CI coverage.

### Fixed

- Remote reconnects now retain unsent drafts, resolve uncertain deliveries,
  rotate sockets without interrupting active sessions, and avoid replaying
  terminal commands after lost acknowledgements.
- Public site and documentation links now resolve to the stable macOS download,
  and release retries work consistently on hosted runners.

### Security

- Terminal and Claude content is end-to-end encrypted between the browser and
  Mac; AWS relays ciphertext and never receives private controller keys,
  terminal plaintext, account credentials, or pairing secrets.
- Account tenancy is derived exclusively from verified Cognito subjects and is
  rechecked across controller registration, ticket issuance, WebSocket
  connection, key lookup, and both relay directions.
- Controllers use non-exportable P-256 keys, signed requests, short-lived
  single-use tickets, replay protection, Keychain-backed Mac identity, and a
  permission-restricted local socket.
- Pairing secrets remain in URL fragments, are removed after redemption, and
  are stored server-side only as salted hashes with expiry and atomic
  consumption.
- Production deployments require a custom domain, verified SES sender,
  Cognito threat protection, required MFA, tenant-state deletion protection,
  private origins, request limits, and explicit resource-retention policies.

## [0.1.0] - 2026-07-25

### Added

- A native macOS terminal with shell integration and structured command records.
- Searchable local command history with automatic secret redaction and private sessions.
- A collapsible Claude assistant that shares explicit terminal, directory, and command context.
- AI chat powered by either a Claude subscription or an Anthropic API key.
- Multiple Claude subscription accounts with per tab selection and live usage windows.
- Permission aware command execution with paste, run once, and session approvals.
- Failure explanation, command reruns, bookmarks, runbooks, and command details.
- Project tools for file search, Git state, diffs, tests, monitored commands, and workspaces.
- A native TerminalDB application icon and a theme aware terminal interface.
- Universal support for Apple Silicon and Intel Macs running macOS 13 or later.
- An in app updater that verifies release checksums, archive paths, architectures, bundle identity, version, code signature, and signing certificate.
- A standalone marketing site with real product screenshots and independent Cloudflare Pages CI.
- Contributor, security, build, test, architecture, threat model, and roadmap documentation.
