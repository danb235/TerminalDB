# TerminalDB Remote account release-candidate QA

This plan qualifies the optional Cognito account path without weakening the
existing one-time-link path. A release fails if any tenant-isolation check,
guest regression, encryption check, or production security gate fails.

## 1. Identity and OAuth

- Start signup from the native Remote Control window and an already-open guest
  terminal. Reject standalone signup without a fresh Mac approval.
- Prove the Mac grant is random, expires in 20 minutes, is stored only as a
  hash, is single-use, and is never placed in an HTTP URL or log.
- Submit username/password directly to Cognito, consume the grant in the
  pre-signup trigger, auto-confirm without email/phone, and complete required
  authenticator-app TOTP setup. Confirm the QR and manual setup key are usable,
  an incorrect or expired six-digit code is rejected, cancellation can restart
  safely, and the next password sign-in requires a fresh TOTP code.
- Confirm password is the only allowed first factor and authenticator-app TOTP
  is the only MFA setup choice. Email, SMS, passkeys, and backup codes must not
  appear as authentication or recovery alternatives.
- Confirm setup recommends a second secure or securely synced authenticator
  copy and clearly warns that losing every copy requires operator assistance.
  Exercise ordinary clock skew, code reuse, throttling, and interrupted setup.
- Prove OAuth uses authorization code with PKCE and rejects a mismatched state.
- Reject an external post-authentication return URL and never place the PKCE
  verifier, access token, or enrollment code in the authorization URL.
- Accept only Cognito access tokens with the required scope; reject missing,
  expired, ID, wrong-client, and wrong-issuer tokens at API Gateway.
- Refresh an expired access token and revoke the refresh token at sign-out.
- Confirm TerminalDB's backend and Mac never receive the Cognito signup
  password; the browser holds it only in the live form state sent to Cognito.

## 2. Tenant boundary

- Derive the tenant only from the verified Cognito `sub`; ignore tenant-like
  fields in bodies, paths, headers, and session metadata supplied by clients.
- For users A and B, prove A cannot list, register a controller for, mint a
  ticket for, connect to, or relay traffic through B's session.
- Repeat equality checks at controller registration, ticket issuance,
  WebSocket connect, Mac controller-key lookup, and both relay directions.
- Return a non-enumerating not-found response for cross-tenant session IDs.
- Prove concurrent registration remains idempotent and the five-controller cap
  self-heals expired records without allowing a race past the cap.

## 3. Mac enrollment, recovery, and encryption

- Start **Connect Account** on another Mac, complete a fresh Cognito
  password-plus-TOTP sign-in, and confirm the signed short-lived Mac bootstrap
  binds to the correct immutable subject without any copied enrollment code.
- Reject an expired, replayed, differently signed, or cross-account Mac
  bootstrap. Require local Mac approval before account enrollment. If a guest session is
  active, end it before claiming the Mac and starting the account session.
- Create a password with the browser password manager and confirm Cognito does
  not ask for it a second time during the same signup. Sign out and verify the
  saved credential is offered from the same TerminalDB authentication domain.
- Cancel before leaving the account introduction and verify the Mac exits its
  setting-up state promptly and can issue a fresh approval.
- Claim an existing link-only Mac without rotating its Keychain identity.
- Reject attempts to transfer an already-owned Mac to a different subject.
- Derive identical Mac/browser ECDH material from an account controller salt;
  prove AWS stores no private key or terminal plaintext.
- Confirm account enrollment creates no unsolicited guest link. Creating a
  guest link explicitly afterward must still work.
- Start password change and account deletion from the desktop panel and confirm
  both open in the normal browser flow. Require a fresh Cognito
  password-plus-TOTP sign-in, reject a token more than five minutes old, and
  confirm possession of the Mac key alone cannot authorize either operation.
  Verify password change rejects the wrong current password, accepts the new
  password only with the existing TOTP factor, rejects pre-change API tokens,
  and disconnects existing account controllers.
- Verify the native Remote Control panel opens inside the terminal, keeps
  Create Account visible, dismisses with its X and Escape, enables account
  creation only after an account-capable agent responds, and
  explains how to clear an older background agent after an app update.
- Move an ad-hoc development build to the canonical Applications location,
  start account creation, and verify the macOS Keychain approval comes to the
  foreground with an explanation in the Remote Control panel. Cancel once and
  confirm retry guidance is readable rather than a raw OSStatus failure.

## 4. Anonymous-link regression

- Run fresh one-time pairing, fragment removal, replay rejection, expiry,
  controller signing, ECDH encryption, ticket consumption, socket connection,
  terminal input, reconnect, revocation, and session end.
- Verify an account-owned Mac can still create a guest link and that the guest
  controller is authorized only for the linked session.

## 5. Web experience

- Sign in on a browser with no saved controller and list every enrolled Mac,
  including online, connecting, and offline status plus last-seen time.
- Add multiple Macs from each Mac's **Connect Account** action, observe
  automatic device discovery, confirm no web enrollment-code UI is offered,
  and confirm each
  online Mac exposes all of its TerminalDB windows and tabs. Open one, switch
  to another session, sign out, and verify account tickets stop immediately.
- Sign back in after logout and confirm the same active account session remains
  discoverable. Delete a disposable account only after the exact `DELETE`
  confirmation, then verify its credentials and previously issued token fail,
  its owned remote records are gone, each Mac clears the revoked account
  binding, and an unrelated one-time link still works.
- Quit TerminalDB on every enrolled Mac. Confirm account password plus TOTP
  sign-in still succeeds, the dashboard stays signed in, every Mac remains
  visible as offline, and the page provides a friendly “open TerminalDB” next
  step rather than an authentication error. Reopen one Mac and confirm it
  automatically transitions through connecting to online with its sessions.
- Exercise phone, tablet, and desktop viewports, keyboard input, accessibility,
  offline/reconnect, controller rotation, and stale-session handling.
- Open Accounts through a one-time session from a pre-account Mac build and
  verify the web app keeps sign-in and the terminal usable, explains the
  required Mac update, and never enters a waiting state.
- Confirm no OAuth token, pairing fragment, enrollment code, or terminal text
  appears in application or access logs.

## 6. Infrastructure and operations

- Build and test all workspaces, compile/sign the macOS app, synthesize both CDK
  stacks with `cdk-nag`, and run the production dependency audit.
- Inspect the synthesized account route for JWT authorization, access-token
  scope, Cognito Plus threat protection, required app-only TOTP, password-only
  first factor, private origins, WAF, no-payload logs, DynamoDB TTL/recovery,
  fresh-authentication enforcement, direct Cognito password change, and
  production deletion protection.
- Verify the pool has no required email/phone attributes, uses `admin_only`
  recovery, and rejects direct signup without the pre-signup grant. Exercise
  alarms, budgets, emergency pairing disablement, controller revocation, and
  operator-only recovery.

## Deployed smoke matrix

Run this final matrix against a disposable development deployment with two
fresh Cognito users and two Macs. It requires deployed AWS resources and is not
replaced by local mocks:

The native live-Mac fixture can redeem an account-bound code without exposing
it in the process list: save the code in a mode-`0600` temporary file and pass
its path to `npm run live:mac -w @terminaldb/test-harness --
--enrollment-code-file /path/to/code`. Remove the file when the fixture stops.

Before the multi-tenant matrix, exercise the real Cognito pool with a
disposable account. The command covers mandatory TOTP, initial and additional
Mac binding, direct Cognito password change, pre-change token revocation, and
fresh-auth account deletion. It prints only named pass/fail checks and deletes
the temporary user and bootstrap records in a `finally` block:

```sh
npm run live:totp -w @terminaldb/test-harness -- \
  --profile stelao --region us-west-2 --stage dev
```

1. User A enrolls Mac A; user B enrolls Mac B.
2. Both users open their own sessions from a second browser and a phone.
3. Attempt every A-to-B session-ID substitution at HTTP, ticket, WebSocket, and
   relay layers; all must fail without revealing ownership.
4. Pair a guest phone to Mac A and prove it cannot enumerate account sessions.
5. Revoke A's browser, sign out, change A's password through the approved Mac
   flow, and verify old tickets, API tokens, controllers, and refresh tokens no
   longer work while the existing MFA factor remains required.
6. Disable both Macs and confirm the devices remain visible as offline, active
   session access disappears immediately, login remains usable, and TTL cleanup
   retains no terminal content. Reopen one Mac and confirm automatic recovery.

Record CloudFormation stack IDs, test-user IDs, timestamps, and pass/fail only.
Never record pairing URLs, enrollment codes, OAuth tokens, or terminal output.

## First-party authenticator enrollment execution record — 2026-08-10

Status: **deployed and visible-product gates passed**.

- Started from a live one-time Mac session in Codex's isolated in-app browser,
  opened Accounts, and created a disposable account through the visible forms.
- Confirmed the enrollment card, QR code, setup key, copy action, code field,
  and help text remained centered and non-overlapping at desktop size. The QR
  and manual setup key were both visible without changing screens.
- Clicked **Copy setup key** and observed the visible success state. Completed
  mandatory TOTP, signed out, then signed back in through Cognito managed login
  with password and a fresh authenticator code.
- Found the enrolled Mac online under **Your Macs**, opened its session, and
  permanently deleted the disposable account through the visible confirmation
  flow. Cognito returned to zero matching QA users.
- The full Playwright responsive suite, repository tests, production build,
  dependency audit, macOS suite, and deployed live TOTP qualification passed.
- No password, authenticator secret, pairing link, token, terminal content, or
  enrollment code was retained in screenshots, logs, or the repository.

## Hosted-signup route guard execution record — 2026-08-10

Status: **deployed and visible-product gates passed**.

- Reproduced a previously started account on Cognito's managed MFA setup page.
  Confirmed this was the hosted fallback at `auth.terminaldb.app`, not the
  first-party enrollment UI deployed at the TerminalDB application origin.
- Required Cognito pre-signup to reserve a live, unexpired Mac approval bound
  to the intended username and app client. Missing, expired, wrong-client,
  cross-username, and replayed grants are rejected before MFA enrollment.
- Added post-confirmation state and idempotent interrupted-signup recovery so a
  user can restart first-party enrollment without making an existing account
  eligible for cancellation cleanup.
- Verified against the deployed pool that a signup without Mac approval is
  rejected before MFA and that approved signup still completes mandatory TOTP.
- Through the visible in-app browser flow, opened a live one-time terminal,
  requested Mac approval, reached the TerminalDB QR and manual-key screen,
  copied the setup key, completed enrollment, and removed the disposable
  account and tenant records afterward.
- Corrected direct-session logout to return to TerminalDB instead of entering
  Cognito managed logout, and cleared the busy state after canceled enrollment
  so the next attempt remains interactive.

## Managed-login branding execution record — 2026-08-10

Status: **deployed and visible-product gates passed**.

- Updated only the existing Cognito managed-login branding resource. The user
  pool, app client, domain, accounts, and deployed relay throttle values were
  unchanged.
- Opened the account flow in Codex's isolated in-app browser and verified the
  live sign-in, account-creation, and password screens use the TerminalDB mark,
  graphite canvas and form surfaces, cyan actions and focus states, and the
  coral error treatment.
- Submitted a nonexistent account through the visible sign-in form and
  confirmed Cognito retained its non-enumerating error while applying the
  branded error treatment.
- Used a disposable Mac-approved Cognito account to reach the real mandatory
  authenticator-app enrollment screen and its invalid-code state. The QR code
  and TOTP secret were not captured or logged.
- Deleted the disposable Cognito user and bootstrap record after the browser
  pass. Cognito returned to zero branding-QA users.
- Infrastructure tests, repository tests, production build, cost guards,
  dependency audit, CDK synthesis, and patch-hygiene checks passed.

## Desktop-first account execution record — 2026-08-10

Status: **local, deployed, and visible-product gates passed**.

- Opened Remote Control inside the installed TerminalDB window, verified the
  visible close control, and confirmed Create Account and Connect Account are
  available before enrollment while Change Password and Delete Account are
  available only after enrollment.
- Opened a fresh one-time link from the Mac in Codex's isolated in-app browser,
  used the visible Accounts sheet to request Mac approval, created a disposable
  Cognito account, and completed mandatory authenticator-app TOTP enrollment.
- Opened the enrolled Mac's live session, logged out, then signed back in
  without a link using username, password, and the existing TOTP factor.
- Quit TerminalDB and its agent, refreshed the signed-in dashboard, and saw the
  enrolled Mac remain visible as offline with the instruction to open
  TerminalDB. Logged out and completed password-plus-TOTP sign-in again while
  every Mac was offline.
- Deleted the disposable account through the visible exact-confirmation flow.
  No password, TOTP secret, pairing link, token, terminal content, or enrollment
  code was retained in screenshots, logs, or the repository.
- Ran the deployed live MFA qualification against the same stack. It covered
  initial and additional Mac binding, direct Cognito password change,
  pre-change token rejection, retained TOTP, fresh-auth deletion, and cleanup.

## Local execution record — 2026-08-08

Status: **release-candidate local and deployed gates passed**.

- Repository production build: passed.
- Protocol, infrastructure, web, and harness tests: 105 passed.
- Playwright phone, tablet, and desktop suite: 92 passed, 1 skipped. The
  skipped desktop touch-target check is intentionally limited to coarse-pointer
  devices; the same check passed on phone and tablet projects.
- macOS interactive and headless suites: passed, including compile, ad hoc
  signature verification, Keychain identity, local socket permissions, secret
  scan, terminal tabs, Claude state, and remote-agent self-tests.
- Universal release build: passed for `arm64` and `x86_64`, version `0.3.0`.
- Development deployment: `TerminalDBRemote-dev` reached `UPDATE_COMPLETE`.
- Live pool policy: username-only, no auto-verified attributes, `admin_only`
  recovery, required TOTP, MFA-capable user-verified passkeys, Plus threat
  protection, and no email/SMS sender.
- Production dependency audit (`npm audit --omit=dev --audit-level=high`): zero
  vulnerabilities. The latest CDK development bundle has one upstream-only
  `brace-expansion` advisory and no fixed CDK release; it is not shipped in the
  app or Lambda artifacts.
- Patch hygiene (`git diff --check`): passed.

## Deployed account and guest execution record — 2026-08-08

- Redeemed a fresh single-use guest link, connected an encrypted browser
  controller, discovered two native-backed tabs, and rendered a live terminal:
  passed.
- Started account creation from that open guest terminal, received the Mac's
  encrypted one-time approval, and verified the username/password form became
  immediately typeable: passed.
- Submitted the password directly to Cognito, auto-confirmed without email,
  completed required TOTP, observed the optional passkey prompt, completed
  PKCE login, bound the waiting Mac, and discovered/opened its account session:
  passed.
- Logged out, signed back in with username/password/TOTP, and rediscovered the
  same session without a link: passed.
- Changed the password through the enrolled Mac. The old password failed, the
  new password required the existing TOTP, the active account controller was
  revoked, and the pre-change API token returned 401: passed.
- Opened a disposable secure link from the actual running pre-account Mac
  binary against the deployed web app. The terminal and sign-in remained
  available, the unsupported create action was absent, and an immediate update
  explanation replaced the indefinite waiting state. Repeated on the automated
  phone, tablet, and desktop projects, then revoked the disposable live
  controller: passed.
- Started a fresh session with the final account-capable native agent, verified
  it advertised account approval, clicked Create account with this Mac in the
  deployed web app, and received the enabled username/password form through a
  real one-time Mac grant. Disabled and removed the temporary session without
  creating a Cognito user: passed.
- Deleted the disposable account from the web after exact `DELETE`
  confirmation. Cognito returned to zero users and no live tenant records
  remained: passed.
- Repeated the backend matrix with two fresh accounts and two independently
  signed Mac identities. Each account listed exactly its own session, and
  cross-tenant controller registration was rejected with a non-enumerating 404
  in both directions: passed.
- Deleted both matrix accounts. Cognito returned to zero users, DynamoDB had no
  live `USER#` records, and the CloudFormation stack remained
  `UPDATE_COMPLETE`: passed.
