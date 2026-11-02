# Shared Claude account QA (0.6.3)

Use only isolated installed QA apps, synthetic subscriptions and disposable
terminal sessions for visible evidence. Never capture provider tokens, browser
authorization codes, pairing material or private terminal contents. Automated
fixtures supplement the visible scenarios below.

## User perspective plan

1. Open Accounts & Usage from the status bar. Check compact account rows, the
   selected execution workstation, details expansion/collapse and a single-Mac
   empty state. New tabs default to This Mac.
2. Open Sync Macs. Pairing remains independent: newly paired Macs are unchecked.
   Enable account sync on both Macs using native checkboxes and Save. Check
   one-sided setup gives a practical counterpart instruction.
3. Add a synthetic reusable sign-in through the normal name/email form and Sign
   In in Browser button (the fixture replaces only the official CLI). Confirm
   that the account appears on another Mac without repeating the flow.
4. Open/resume a terminal on the other Mac. Choose the shared account via Use on
   This Tab. Confirm its execution Mac remains visible and other tabs keep their
   selected account. Launch the fixture Claude command; inspect only its success
   marker, never its credential environment or output.
5. Expand Usage & Settings, collapse it, renew the synthetic sign-in, and remove
   it through the normal confirmation. Check delayed old state does not restore
   it. Ordinary sign-in/history preservation must be checked independently.
6. Disconnect a sync Mac, add an account on the other Mac, quit/reopen its
   interface, reconnect and confirm automatic arrival. Repeat with a removal.
   Check the same behavior over the user's VPN and after sleep/wake when those
   physical scenarios are available.
7. Disable account sync and verify existing terminal control continues. Revoke
   a disposable pairing and confirm no subsequent account transfer. Do not
   revoke production pairings or erase real subscriptions during QA.

## Automated coverage

`make test-ci` covers native regressions, framing/authorization, persistent host
sessions, Keychain code identity, causal merge/removal, replay, account identity,
expiry, directory withdrawal, Unicode normalization and copied-data writers.
`make -C apps/macos qa-peer-network` exercises actual native hosts and mutually
authenticated agents: explicit two-sided opt-in, forbidden remote export/import,
account selection and Claude launch, offline addition/removal with restart,
pairing mismatch/unapproved denial, takeover, agent restart and revocation.

## Execution record

Automated: `make test-ci` passed: 96 terminal-surface checks, native product
self-tests, 127 native peer/account checks, 23 persistent-session checks,
signature/icon/secret checks and shell-hook checks. The native agent integration
suite passed 26 scenarios. Universal arm64/x86_64 build passed before the final credential-repair follow-up.
The earlier 125 native checks also passed on the physical mini and MBP.
The final two checks cover repairing Keychain state from unchanged metadata.

Visible: two isolated installed apps on one physical Mac passed empty state,
fingerprint comparison/approval on both interfaces, unchecked sharing after
pairing, two-sided sync controls, account addition, automatic appearance in the
second picker, per-tab selection, details, renewal, shared-removal confirmation,
remote workstation heading, new tabs defaulting to This Mac, and remote fixture-Claude launch. Pausing only a
disposable networking helper proved an added account stayed local while offline
and appeared automatically after reconnect. A removal made while a peer was
paused also propagated when it resumed, without resurrecting the account.

Physical: the existing production pinned LAN connections to both other Macs
passed, without changing trust or running work. Separately installed physical QA
helpers were reachable by TCP but did not complete new secure pairing; the
three-Mac synthetic account pass is pending. No production pairing or credential
was replaced to bypass that failure. Visible pairing/account checks on two
physical Macs, real provider browser authorization, physical VPN disconnect /
reconnect and sleep/wake for shared accounts remain pending. Synthetic success
does not substitute for those scenarios. Existing networking acceptance evidence
is in `native-peer-qa.md`.

Merged installation and About verification are recorded during handoff. No
release tag or public release is part of this change.
