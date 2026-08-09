# Testing guide

## Fast local checks

```sh
make test-ci
python3 marketing/test_site.py
git diff --check
```

`make test-ci` builds the application, runs the native self test suite, verifies
the code signature, verifies the icon bundle, scans the working tree for
Anthropic API keys, and checks the Claude tab state bridge.

## Full local checks

```sh
make test
```

The full target adds background tab QA. It opens native windows during the test,
so use `make test-ci` when you need the app to remain in the background.

Focused targets are available:

```sh
make qa-signature
make qa-icon
make qa-secrets
make qa-tabs
make qa-claude-state
```

## Native self tests

The application binary supports:

```sh
build/TerminalDB.app/Contents/MacOS/TerminalDB --self-test
```

The self tests cover terminal parsing, command blocks, history, private
sessions, permission classification, read only inspection, symlink escape
protection, assistant command actions, patch review, profiles, usage parsing,
and product state.

## Visual QA

The application provides deterministic visual fixtures:

```sh
build/TerminalDB.app/Contents/MacOS/TerminalDB --visual-qa
```

Additional arguments select history, inspector, split, and scrollback fixtures.
The current manual and adversarial audit is tracked in
[QA_AUDIT.md](../QA_AUDIT.md).

Visual QA should verify:

- every top level menu and window opened from it
- normal, private, split, and tabbed terminal states
- empty, loading, success, failure, and destructive permission states
- long paths, large output, narrow windows, and multiple Claude profiles
- keyboard focus, VoiceOver labels, contrast, truncation, and scroll behavior
- the app icon at Finder, Dock, About, and alert sizes

## User-perspective acceptance QA

For every user-visible feature, write a short journey-based QA plan before the
final handoff and execute it through the same installed app and deployed web
interface a user opens. Click the real menu items and buttons, type into the
real forms and terminal, and verify the visible success, error, and recovery
states. Automated tests and developer fixtures remain useful regression gates,
but do not replace this acceptance pass.

For TerminalDB Remote account changes, include these journeys:

1. Open **TerminalDB → Remote Control…** in the installed app and start account
   creation.
2. Open a one-time guest session, choose **Accounts**, and start account
   creation with that Mac.
3. Complete username, password, and MFA setup; verify the Mac appears without
   sharing another link.
4. Sign out, sign back in, and open the same live terminal session.
5. Create another one-time guest link and verify account creation remains
   optional.
6. Verify visible guidance when the desktop app, Mac agent, network, or session
   is unavailable.

Use a disposable account and delete it when the pass is complete. Keep secrets,
pairing material, tokens, and terminal content out of the QA record.

## CI separation

Application CI ignores marketing only changes. Site CI validates changes under
`marketing/` and deploys only the static site. Release CI runs only for version
tags.
