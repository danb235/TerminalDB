# Shared AWS SSO renewal QA

Use only synthetic accounts for screenshots and recordings. Do not capture
browser authorization codes, device fingerprints, credentials, or real terminal
contents. Keep automated results and visible outcomes separate.

## Automated regression plan

- One named SSO session serves two account/role profiles; a third profile has a
  different named session at the same portal. A fourth same-session profile is
  not enabled for sharing.
- A cancelled/failed login and delayed old callbacks preserve cached credentials
  and cannot overwrite a newer login. A CLI success with expired/missing cache
  does not claim the SSO session is current.
- Successful session login renews already-enabled sibling profiles, updates local
  authentication status for unshared siblings, and never enables their sharing.
- Original native aliases and mixed named/legacy receiving mappings preserve
  their local SSO cache; imported sibling roles share a private session while
  unrelated sessions stay isolated.
- Expired, missing, malformed, wrong-portal, unsafe, and oversized cache files
  cannot appear as a current SSO sign-in. Catalogs contain metadata only.
- Cached access with expired SSO has a visible Sign In action and independent
  expiry text; signing-in state applies to all affected profile rows. Validate
  native layout at normal and narrow panel sizes.

## Visible native plan

1. Open TerminalDB > AWS Access. Confirm an expired shared session is labelled
   for renewal even if one profile has usable cached access. Sign In is directly
   available; the cached access expiry remains clear.
2. Click Sign In beside either sibling profile. Confirm the official browser
   login opens and related rows show sign-in progress. Cancel one attempt and
   confirm the renewal warning and cached access remain.
3. Complete one browser sign-in through the normal controls. Confirm related
   profiles reflect the renewed session, unrelated sessions retain their state,
   and unselected profiles remain unshared.
4. Through normal terminal input, verify both configured sibling profiles can
   obtain their own AWS identities without another browser login. Capture only
   success/failure metadata, never credentials or terminal output.
5. Reopen AWS Access and verify status persists. On the installed canonical app,
   open About and confirm version 0.6.6 (15).

## Installation safeguard

AWS services run inside the session host. The existing host cannot pick up this
fix while retaining its in-memory old implementation. Back up app/data and
protect active work before the coordinated host restart. Do not stop active
sessions without the user's explicit choice. Use the existing stable CI signer
for the install artifact; this workflow creates no public release or version tag.

## Executed before merge

Automated: `make test-ci` passes with 96 terminal-surface checks, 250 AWS
interface/layout checks, 449 native peer/service/configuration checks, and 23
persistent-session integration checks. Workflow syntax and whitespace checks
pass. Independent source review covers session isolation, cancellation fencing,
bounded cache metadata reads, and least-privilege manual signing.

Visible native/browser QA uses one temporary isolated app with synthetic
profiles and a localhost approval page; it contacts no real AWS service:

- The normal app menu opens AWS Access. Engineering has cached access while its
  team SSO session needs renewal; the Sign In action is visible.
- Clicking Engineering Sign In shows signing-in progress on Engineering and
  Data, which share the session. The separate session retains its warning.
- Cancel Sign-In preserves cached access, restores the warning, and keeps Sign
  In available.
- A second Sign In followed by the normal Complete Sign-In browser button marks
  both related profiles signed in. Data remains unshared, and the separate
  session remains expired.
- Reopening the refreshed interface confirms both current-session rows say
  Sign In Again, including the sibling without cached role credentials. The
  footer explanation is concise and the native rows/actions align.
- The temporary QA app, its server and helpers are removed after the pass;
  canonical running apps and sessions are preserved.

Real AWS sign-in and installed-app About checks remain pending installation and
the user's protection of active work. Synthetic UI outcomes above do not
substitute for that live provider check.
