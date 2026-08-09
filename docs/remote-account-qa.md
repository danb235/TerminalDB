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
  TOTP or user-verified passkey setup.
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

- Redeem a new account-bound enrollment code once; reject replay and expiry.
- Require local Mac approval before account enrollment. If a guest session is
  active, end it before claiming the Mac and starting the account session.
- Claim an existing link-only Mac without rotating its Keychain identity.
- Reject attempts to transfer an already-owned Mac to a different subject.
- Derive identical Mac/browser ECDH material from an account controller salt;
  prove AWS stores no private key or terminal plaintext.
- Confirm account enrollment creates no unsolicited guest link. Creating a
  guest link explicitly afterward must still work.
- Require Touch ID or the Mac login password for desktop password changes and
  account deletion. Verify a change rejects the old password, accepts the new
  password only with the existing MFA factor, rejects pre-change API tokens,
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

- Sign in on a browser with no saved controller and list every active enrolled
  Mac session.
- Add a Mac, observe automatic session discovery, open it, switch to another
  session, sign out, and verify account tickets stop immediately.
- Sign back in after logout and confirm the same active account session remains
  discoverable. Delete a disposable account only after the exact `DELETE`
  confirmation, then verify its credentials and previously issued token fail,
  its owned remote records are gone, and an unrelated one-time link still works.
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
  scope, Cognito Plus threat protection, required TOTP, private origins, WAF,
  no-payload logs, DynamoDB TTL/recovery, and production deletion protection.
- Verify the pool has no required email/phone attributes, uses `admin_only`
  recovery, and rejects direct signup without the pre-signup grant. Exercise
  alarms, budgets, emergency pairing disablement, controller revocation, and
  trusted-Mac recovery.

## Deployed smoke matrix

Run this final matrix against a disposable development deployment with two
fresh Cognito users and two Macs. It requires deployed AWS resources and is not
replaced by local mocks:

The native live-Mac fixture can redeem an account-bound code without exposing
it in the process list: save the code in a mode-`0600` temporary file and pass
its path to `npm run live:mac -w @terminaldb/test-harness --
--enrollment-code-file /path/to/code`. Remove the file when the fixture stops.

1. User A enrolls Mac A; user B enrolls Mac B.
2. Both users open their own sessions from a second browser and a phone.
3. Attempt every A-to-B session-ID substitution at HTTP, ticket, WebSocket, and
   relay layers; all must fail without revealing ownership.
4. Pair a guest phone to Mac A and prove it cannot enumerate account sessions.
5. Revoke A's browser, sign out, change A's password through the approved Mac
   flow, and verify old tickets, API tokens, controllers, and refresh tokens no
   longer work while the existing MFA factor remains required.
6. Disable both Macs and confirm session indexes disappear immediately and TTL
   cleanup retains no terminal content.

Record CloudFormation stack IDs, test-user IDs, timestamps, and pass/fail only.
Never record pairing URLs, enrollment codes, OAuth tokens, or terminal output.

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
