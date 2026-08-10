# Changelog

All notable changes to TerminalDB are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and TerminalDB uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- The signed-in web dashboard now keeps every enrolled Mac visible with an
  online, connecting, or offline state and a last-seen time. Account login and
  device inventory continue to work when every Mac is offline.
- Enrolled Macs reconnect their account session automatically when TerminalDB
  starts, so multiple Macs can become remotely available without creating new
  links or manually reopening Remote Control.
- A disposable live Cognito QA exercise covers mandatory TOTP enrollment,
  password-only rejection, invalid and valid authenticator codes, returning
  sign-in, and cleanup without printing credentials or TOTP secrets.

### Changed

- Every account now requires password plus authenticator-app TOTP. Email, SMS,
  passkeys, and backup codes are not offered as authentication or recovery
  alternatives. Signup warns users to keep a second secure authenticator copy
  because losing every copy requires operator-assisted recovery.

### Fixed

- Account creation now brings the macOS Keychain approval forward when a
  moved or updated local build needs permission to reuse the Mac's existing
  non-exportable identity. The native window explains the approval instead of
  appearing to hang, and cancellation returns actionable guidance rather than
  a raw OSStatus error.
- Deleting an account from the web now causes enrolled Macs to discard the
  revoked account binding on their next live reconnect, return to one-time-link
  mode, and stop retrying a permanently deleted principal.

## [0.3.0] - 2026-08-08

### Added

- Mac-approved, email-free TerminalDB account creation from the native Remote
  view or an already-open one-time web terminal. Users choose a username and
  password, complete required TOTP or a user-verified passkey, and the waiting
  Mac connects automatically.
- A signed-in web session hub that discovers and opens every active terminal
  session owned by the account without exchanging secure links.
- Account logout and exact-confirmation account deletion in the web app, plus
  Touch ID or Mac-password protected password changes and account deletion in
  the desktop app.
- A reusable QA plan and automated coverage for Mac approval, Cognito signup,
  tenant isolation, credential revocation, account cleanup, and the existing
  anonymous-link workflow.

### Changed

- Cognito accounts are username-only and no longer require, collect, verify, or
  send email or SMS. Account recovery is administrator-only; enrolled Macs can
  change passwords or delete the account without becoming an MFA bypass.
- Account signup uses a TerminalDB form that sends the password directly to
  Cognito. TerminalDB's backend and Mac never receive the account password.
- Account enrollment upgrades the Mac's existing non-exportable Keychain
  identity, while account-owned Macs retain the same optional one-time guest
  links for temporary access.
- Required MFA supports TOTP and user-verified passkeys in Cognito's
  multi-factor WebAuthn mode, with Plus threat protection enabled.

### Fixed

- Account approval messages now pass through the encrypted relay allowlist in
  both directions, and the approved signup form no longer inherits the
  preceding “Waiting for Mac” disabled state.
- Existing guest-enrolled Macs can be atomically attached to an account without
  a DynamoDB reserved-word failure.
- The universal release build links LocalAuthentication for the new Touch ID
  protected account actions.
- Browsers now discard revoked local account credentials and return to a clear
  sign-in state immediately after native account management changes access.
- Web and native account creation now negotiate explicit Mac-agent support.
  Older builds explain the required update instead of offering an action the
  running agent cannot acknowledge.

### Security

- Signup requires a random 20-minute Mac grant backed by a P-256 proof. Only a
  hash is stored, the Cognito pre-signup trigger consumes it once, and direct
  unapproved signup is rejected.
- Account ownership comes exclusively from verified Cognito access-token
  subjects and is rechecked across HTTP, ticket, WebSocket, key lookup, and
  ciphertext relay boundaries. Live two-tenant QA confirmed isolated session
  discovery and non-enumerating cross-tenant rejection.
- Password changes reject pre-change API tokens, revoke account controllers,
  disconnect their sockets, invalidate Cognito sessions, and preserve the
  existing required MFA factors.
- Account deletion tombstones the tenant first, disconnects remote sockets,
  removes controllers, sessions, enrollments, and Mac ownership records, then
  globally signs out and deletes the Cognito user.

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
