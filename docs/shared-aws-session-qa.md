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
   open About and confirm the intended installed version.

## Installation safeguard

AWS services run inside the session host. The existing host cannot pick up this
fix while retaining its in-memory old implementation. Back up app/data and
protect active work before the coordinated host restart. Do not stop active
sessions without the user's explicit choice. Use the existing stable CI signer
for the install artifact. Public releases follow the release workflow after its
explicit authorization and the required checks.

## SSO renewal evidence for 0.6.6

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

Real AWS provider and installed-app outcomes are recorded separately from this
synthetic pass. Synthetic UI outcomes do not substitute for a live provider
check.

## Access sharing and receiving profile polish

Automated plan:

- Run `apps/macos/Tests/aws-peer-network-qa.py` against the installed app. The
  official-CLI fixture honors named `--sso-session` logins and creates only a
  synthetic local SSO cache. Shared role credentials reach the receiving host;
  the source SSO token cache does not.
- Keep the existing trust, bilateral consent, authorization, role identity,
  credential-process, offline recovery, replay, withdrawal, and revocation
  assertions.
- Add a receiving native SSO profile with an expired local cache. An occupied
  name requires explicit migration approval. After migration, valid received
  role credentials work through that profile while the local SSO cache remains
  expired and unchanged. Removing the mapping restores the original native
  configuration and preserves the shared credential's original expiry.

Visible plan:

1. On a sender with a valid existing AWS login, open **AWS Access → Profiles**.
   Confirm **Share Access** is directly visible and publishes the chosen role
   through the normal button without another browser sign-in.
2. Open **Sharing** on both paired Macs and enable AWS sharing. Verify that
   pairing or Claude sharing alone does not enable AWS transfers.
3. On the receiving Mac, choose **Use on This Mac** for a shared profile whose
   suggested name is unused. Confirm it imports with one click and no redundant
   name form. For an occupied name, verify the alias or migration confirmation
   before any local profile changes.
4. Confirm a usable receiving profile says **Ready on This Mac**, identifies its
   providing Mac with **From …**, and shows the shared credential expiry. An
   expired local SSO cache, including one belonging to an original native
   profile, does not replace this status with a mandatory local login warning.
5. Use **Sync Now** through the normal controls. Confirm **Sign In Here** is
   available as an optional local login and distinguish it from requesting
   renewed shared access.
6. Verify cancelled sign-in, offline source and expired shared credentials leave
   practical recovery actions. Test the normal CLI/SDK profile mapping without
   displaying or recording credentials.

Record automated counts separately from the visible outcomes. The fixture
network pass runs two native agent instances with fresh temporary identities;
it does not represent two physical Macs or a real AWS identity provider.

Automated network evidence for this polish: the updated in-repository fixture
passes **22 native-agent integration checks** against installed **0.6.6 (15)**.
The 19 baseline cases remain, with three additional checks for protected native
profile migration, shared access despite expired receiver SSO, and exact native
configuration restoration. The fixture needs no private login adapter. Production
app/helper PIDs, AWS configuration, credentials and trust digests stay unchanged;
all newly created fixture processes and directories are cleaned up. These are
automated results; the visible sharing controls require the native plan above.

## Native UI evidence for the 0.6.7 candidate

Final `make test` and `make test-ci` both pass: **744 AWS interface/layout
checks**, **547 native peer/service/configuration checks**, **96 terminal-surface
checks**, and **23 persistent-session integration checks**. Bundle signatures,
icons, secret checks, background tabs and Claude hooks pass. The full universal
0.6.7 (16) build verifies arm64 and x86_64 in the app and both helpers; the Intel
binary also passes its 744 interface checks under Rosetta.

The final 0.6.7 binary also passes the updated **22 native-agent AWS integration
checks**, including credential-process access through a migrated receiver whose
original SSO cache remains expired, protected name conflicts, and restoration
of the original configuration. These use synthetic credentials on one physical
Mac; they are separate from the earlier 0.6.6 run and physical provider checks.

Local universal verification uses a complete, hash-verified Apple Swift 6.2.3
Command Line Tools/SDK package with per-command `DEVELOPER_DIR`. The newer local
6.4 toolchain lacks Intel compatibility runtime slices. The compatible package
keeps the macOS 13 minimum and leaves the global developer selection unchanged.
The manual static-library link explicitly includes its C++ runtime. A concurrent
expiry-file race in the synthetic AWS CLI fixture is fixed with a file lock;
production credential handling is unchanged.

Visible QA uses an isolated native app with synthetic profiles and a local
browser approval page. Through the normal buttons, menus, forms, and navigation:

- **Share Access** publishes a selected signed-in native profile without
  another browser login. A free incoming name imports with one click through
  **Use on This Mac**.
- Native profile migration supports **Cancel** without changing the profile,
  then **Use Profile** to complete the mapping. An occupied name suggests a
  different alias; cancelling preserves the existing profile.
- A source sign-in shows related-session progress. **Cancel Sign-In** preserves
  cached access. Completing the normal browser approval renews the source and
  related session while the unselected sibling remains unshared.
- A healthy receiver shows **Ready on This Mac**, its providing Mac, and access
  expiry. Its **Profile Details** labels the retained local sign-in as optional.
  Closing and reopening the panel preserves the ready state.
- An expired receiver exposes **Sync Now** and **Sign In Here**; the local
  fallback can be cancelled normally. A conflicting identity opens its
  explanation through **Review…**.
- **Choose Macs** opens **Sharing**. In the empty scene, **Set Up Sharing**
  opens **Sharing** and shows the pairing instructions.
- Rows and action columns align visibly at the default 700-point width and
  when expanded. A manual edge-resize attempt did not change the window width;
  600, 700, and 1000-point geometry coverage is automated, not a visible
  600-point outcome.

The visible pass found duplicate signing-in text and an old sign-in completion
message overwriting newer sync feedback. Both are corrected, and the final
visible rerun passes on the updated native slice: each related row has one
**Signing In…** action label while retaining useful SSO/source context; normal
browser completion updates the session without sharing the unselected sibling;
and **Sync Now** keeps its checking feedback after **Sharing → Profiles**
refreshes. Healthy receiver readiness and empty-scene setup still pass. The QA
app quits normally and its owned browser approval tab is closed. Its app,
helpers, server, private state and three Launch Services registrations are
removed afterward. Canonical process IDs, AWS configuration/credentials and
device trust digests remain unchanged. Standard application folders on all
three Macs contain no old TerminalDB QA installations.

This is the premerge acceptance record. Merged-main installation, physical
About/normal-use checks, real AWS identity checks and public download
verification are recorded separately during the release handoff. Synthetic
approval does not substitute for those checks.
