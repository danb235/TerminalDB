# TerminalDB Remote account release-candidate QA

This plan qualifies the optional Cognito account path without weakening the
existing one-time-link path. A release fails if any tenant-isolation check,
guest regression, encryption check, or production security gate fails.

## 1. Identity and OAuth

- Complete Cognito managed-login signup with username, verified email,
  password, and required TOTP.
- Prove OAuth uses authorization code with PKCE and rejects a mismatched state.
- Accept only Cognito access tokens with the required scope; reject missing,
  expired, ID, wrong-client, and wrong-issuer tokens at API Gateway.
- Refresh an expired access token and revoke the refresh token at sign-out.
- Confirm the web app never accepts or stores the Cognito password.

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

## 3. Mac enrollment and encryption

- Redeem a new account-bound enrollment code once; reject replay and expiry.
- Claim an existing link-only Mac without rotating its Keychain identity.
- Reject attempts to transfer an already-owned Mac to a different subject.
- Derive identical Mac/browser ECDH material from an account controller salt;
  prove AWS stores no private key or terminal plaintext.
- Confirm account enrollment creates no unsolicited guest link. Creating a
  guest link explicitly afterward must still work.

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
- Exercise phone, tablet, and desktop viewports, keyboard input, accessibility,
  offline/reconnect, controller rotation, and stale-session handling.
- Confirm no OAuth token, pairing fragment, enrollment code, or terminal text
  appears in application or access logs.

## 6. Infrastructure and operations

- Build and test all workspaces, compile/sign the macOS app, synthesize both CDK
  stacks with `cdk-nag`, and run the production dependency audit.
- Inspect the synthesized account route for JWT authorization, access-token
  scope, Cognito Plus threat protection, required TOTP, private origins, WAF,
  no-payload logs, DynamoDB TTL/recovery, and production deletion protection.
- In production, verify the SES identity and sandbox exit before enabling public
  signup. Exercise alarms, budgets, emergency pairing disablement, controller
  revocation, and account recovery.

## Deployed smoke matrix

Run this final matrix against a disposable development deployment with two
fresh Cognito users and two Macs. It requires deployed AWS resources and is not
replaced by local mocks:

1. User A enrolls Mac A; user B enrolls Mac B.
2. Both users open their own sessions from a second browser and a phone.
3. Attempt every A-to-B session-ID substitution at HTTP, ticket, WebSocket, and
   relay layers; all must fail without revealing ownership.
4. Pair a guest phone to Mac A and prove it cannot enumerate account sessions.
5. Revoke A's browser, sign out, reset A's password/TOTP through the approved
   recovery flow, and verify old tickets and refresh tokens no longer work.
6. Disable both Macs and confirm session indexes disappear immediately and TTL
   cleanup retains no terminal content.

Record CloudFormation stack IDs, test-user IDs, timestamps, and pass/fail only.
Never record pairing URLs, enrollment codes, OAuth tokens, or terminal output.

## Local execution record — 2026-08-08

Status: **local release-candidate gates passed; deployed smoke gate not run**.

- Repository build: passed.
- Protocol, infrastructure, web, and harness tests: 90 passed.
- Playwright phone, tablet, and desktop suite: 77 passed, 1 skipped. The
  skipped desktop touch-target check is intentionally limited to coarse-pointer
  devices; the same check passed on phone and tablet projects.
- macOS compile/sign and native self-test suite: passed, including the existing
  guest pairing secret path and the new account controller-salt path.
- Development and production CDK synthesis with `cdk-nag`: passed.
- Production-only assertions: custom domain/certificate and verified SES sender
  are mandatory; Cognito and DynamoDB are retained and deletion-protected.
- Production dependency audit at high severity: zero vulnerabilities.
- Patch hygiene (`git diff --check`): passed.

The deployed smoke matrix above remains a release blocker until it is run in a
disposable AWS environment with two fresh accounts and two Macs. Local mocks do
not qualify that gate, and this QA run did not create or mutate cloud resources.
