# AWS Ready and automatic renewal QA

Use synthetic credentials for recorded UI scenarios. Never record real terminal
contents, authorization codes, account identifiers, credentials, or Keychain
dialogs. Report automated and visible results separately.

## Automated plan

- Usable source and receiving profiles show Ready without a prominent expiry,
  cached-token warning, Refresh Access, or Sign In Again control.
- Details contains actual credential expiry and Check Access. A successful
  check may preserve the existing expiry; it never promises eight more hours.
- Healthy Details and local connection/permission failures do not display an
  unnecessary sign-in button. Confirmed required authentication and an
  unavailable receiving profile retain the appropriate sign-in recovery.
- An expired SSO access-token cache with successful silent CLI renewal does not
  require browser sign-in. Explicit authentication-required responses do.
- Connection, timeout, permission, malformed-response, and wrong-identity
  failures never masquerade as required browser sign-in. Still-valid access
  remains available while recovery proceeds.
- The service renews selected sources near expiry. Expiry stays authoritative,
  credentials are never replayed beyond it, and sharing remains selected.
- Checking an unshared profile does not enroll, publish, or migrate it. Check
  work, retries, private output, and simultaneous jobs remain bounded.
- A received profile uses its shared credentials independently of any original
  expired local SSO login. Existing trust and authorization checks still apply.

## Visible plan

1. Through the normal app menu, open AWS Access. Review aligned profile rows
   at the normal and narrow supported widths. Working profiles say Ready.
2. Open a row's Details. Verify expiry is secondary information, the source is
   clear, and Check Access has an explanation that it does not reset duration.
3. Click Check Access. The panel updates without requiring another browser
   sign-in or closing and reopening Details. Close Details normally.
4. In synthetic scenarios, exercise silent renewal, required authentication,
   a connection failure, and denied access. Only the authentication-required
   scenario offers Sign In as the necessary recovery.
5. On each of the three physical Macs, verify About reports 0.6.9 (18), AWS
   Access shows the existing usable profiles as Ready, and normal Details and
   Check Access work. Verify the expected account and role for both shared
   profiles with success booleans only and no additional AWS sign-in.
6. Confirm the current app, paired-device trust, account configuration, and
   approved sharing remain intact. Remove temporary QA apps and helpers.

Physical sleep/wake, offline LAN, and VPN transition scenarios are outside this
AWS presentation pass unless explicitly executed; existing networking tests
do not substitute for reporting that limit.

## Installation and release

Preserve active work and obtain an explicit choice before ending sessions for
the session-host upgrade. Back up privately on each Mac, verify the stable
signer and Apple Silicon architecture, then install the signed candidate from
the merged source. Execute installed-app checks before publishing the version
tag. Keep the public release tag immutable and verify the published download.

## Local candidate outcomes

Automated checks pass on 0.6.9 (18): `make test`, `make test-ci`, and the release
build. Results include 96 terminal-surface checks, 790 AWS interface/layout
checks, 668 native peer/service/configuration checks, and 23 persistent-session
checks. All three bundled executables contain exactly arm64 code, retain the
macOS 13 minimum, and pass strict code-signature verification. Static marketing
checks and whitespace validation also pass.

Visible native testing uses an isolated app with synthetic profiles and fake
AWS responses, through the normal app menu and controls:

- Engineering and Data show Ready despite deliberately expired synthetic SSO
  access-token timestamps. Main rows contain no expiry clock or renewal action.
- Details shows actual credential expiry, the non-reset explanation, Check
  Access, and Done. A successful check updates in place and preserves the same
  expiry without opening a sign-in page.
- The Offline connection failure and Restricted permission failure have
  distinct guidance and no sign-in button in Details. The explicit
  authentication-required case offers sign-in.
- Default-size rows and Details remain aligned. Automated AppKit layout checks
  additionally cover the narrow supported width; a separate visible resize is
  not claimed here.
- The isolated app closes through normal Quit. All owned QA apps, helpers,
  sessions, and temporary data are removed; canonical work remains unchanged.

The physical installed-app pass on all three Macs follows the signed build
from the merged commit. Its live provider outcomes are reported separately from
these synthetic checks before publication.
