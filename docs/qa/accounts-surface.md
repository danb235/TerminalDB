# Main-window Claude and AWS Accounts QA

Exercise normal native controls using synthetic identities first, then the
installed application on three physical Macs. Keep visible outcomes separate
from automated assertions. Never record real terminal contents, credentials,
authentication codes, or private account details.

## Normal account navigation

- Start with the terminal visible. Click Claude in the footer: Accounts opens
  with Claude selected, the execution Mac named once, and the tab's account
  clearly selected. Choose another account and verify only that terminal's next
  Claude launch changes.
- Click AWS: the same Accounts surface selects AWS. Multiple ready profiles are
  shown independently. Opening this view never changes `AWS_PROFILE`, profile
  mappings, sharing choices, or another window's account selection.
- Switch Claude/AWS within Accounts. Open and close Details. Return from Sharing
  using Back. Close with X and Escape; keyboard focus returns to the intended
  terminal, and returning from another app never types behind an open pane.
- Use wide and narrow windows, long names, several profiles, and empty lists.
  Check aligned action columns, visible provider names in the footer, useful
  truncation, bounded scrolling, keyboard navigation, and accessibility labels.
  Wide windows retain a visible terminal beside Accounts.

## Workstation and recovery

- Open local and remote tabs and a split using different execution Macs. Click
  each footer and verify the panel and actions use that pane's Mac. Switch tabs,
  windows, and focused splits while Accounts is open; a view is never reparented
  into another window or relabeled with another Mac's data.
- Verify a receiving Mac shows Ready from shared credentials even when its
  retained native SSO cache is expired. Details shows actual credential expiry
  separately from unavailable interactive-sign-in expiry.
- Exercise disconnect/reconnect, stale status, older helpers, and late replies
  with fixtures. A disconnected or outdated helper shows recovery guidance,
  never fresh Ready, an empty authenticated account list, or a false Sign In.
- Verify a noncontroller can read status but must Take Control before remote
  changes. Stale controller requests, including requests queued before takeover,
  cannot change profiles. Remote clients cannot request credential exports,
  sync management, or browser authentication on the execution Mac.

## Authentication and privacy

- In a synthetic confirmed-authentication-needed state, click Sign In on This
  Mac from a remote profile. Verify only the separate local management transport
  receives the start request and browser sign-in remains local. No remote tab
  target changes and no sharing permission or profile alias is enabled silently.
- Exercise locally routed Cancel, same-profile replacement, closing/reopening
  Accounts, stale callbacks, failed sign-in, and missing local SSO metadata with
  fixtures. A stale attempt cannot cancel another job or claim another job's
  success. Console-login profiles requiring local setup receive honest guidance.
- A native sharing source with a failing local provider and usable incoming
  access offers Use Shared Access. Before confirmation, its configuration and
  source enrollment stay unchanged. Confirmed migration backs up settings,
  selects the received provider, and stops the obsolete local source. Expired,
  conflicting, or absent incoming access cannot trigger that path.
- With real credentials, use normal Details → Check Access on existing shared
  profiles on all three Macs and confirm expected identity/role in memory.
  Record only booleans/categories. Do not invalidate real access just to force
  another browser sign-in. Report any real browser scenario not exercised as
  pending; synthetic authentication is not a substitute for that scenario.
- Confirm routine footer updates and opening Accounts perform cached metadata
  reads without initiating AWS/Keychain access or CLI checks. Protect shell work
  before installation and preserve new work throughout inspection and cleanup.

## Handoff

Run automated native/interface/protocol tests, build, open and merge the feature
PR after required checks, update the primary checkout, and install the signed
merged build using make install. Verify installed About on all three Macs.
Remove only owned QA apps, helpers, registrations, and temporary awake holds.
Publish a public release only with the user's explicit release authorization.

## Feature verification record

Before installation, the isolated native app passed these visible scenarios
using fictional profiles and an offline fake provider:

- Both footer controls open the same Accounts surface with the correct service
  selected; Details, Sharing, Back, X, and Escape navigate normally.
- The default window and a zoomed wide window show aligned rows and actions.
  Native split terminals retain both footer controls. Exact narrow-width and
  long-label geometry is covered by automated assertions, not physical resizing.
- Check Access moves from checking to Ready. Connection failure, denied access,
  and confirmed authentication need have distinct footer states. An unsuccessful
  sign-in retains the direct retry action and does not discard usable access.
  Healthy sibling profiles retain Ready through failed or cancelled sign-in.
  A later successful access check clears that profile's sign-in requirement
  and removes temporary Updating or obsolete failure feedback.
- Details shows credential expiry and explains when interactive sign-in expiry
  is unknown. A stale, refreshable SSO cache alone does not request sign-in.
- Empty Claude accounts, switching providers, and returning keyboard focus to
  the terminal work. A normal typed test command completes after dismissal.

Each isolated app, its helper processes, registrations, and disposable state
was removed after use. Production configuration and running-app baselines were
unchanged. No real provider authentication was initiated for these scenarios.

Installed-app checks on three Macs and real shared-profile checks are pending
for this build. The incoming-source migration confirmation has automated
model/interface/service coverage; a visible nonlocal migration remains pending.
Real browser authentication from a remote tab, switching between
real Claude accounts, and physical sleep/VPN recovery have not been newly
exercised for this change; automated fixtures cover their routing and recovery
boundaries. Do not count those fixtures as physical outcomes.

Automated validation of the frozen source: release build, make test, and
make test-ci pass. Counts are 96 terminal-surface assertions, 868 AWS interface
assertions, 832 native peer/service assertions, and 23 persistent-session
integration scenarios, plus terminal, shell-hook, signature, icon and secret
checks. These counts are separate from the visible outcomes above.
