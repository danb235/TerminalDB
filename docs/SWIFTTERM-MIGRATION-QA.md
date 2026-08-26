# SwiftTerm migration and acceptance plan

Status: implementation built; acceptance remains **incomplete**. Automated
regressions and the core visible Claude flows passed. The remaining visible
integration checks below must pass before merge/install. Public release is not
part of this change.

## Architecture and safety boundaries

- Pin SwiftTerm to a reviewed release and commit the dependency lockfile.
- SwiftTerm owns parsing, cells, cursor, primary/alternate buffers, selection,
  Unicode width, scrolling, and rendering. Do not run the old parser in parallel.
- Preserve TerminalDB's existing PTY lifecycle, serialized/backpressured input,
  tabs/splits, shell integration, accounts, and encrypted remote transport.
- Keep ledger metadata outside the terminal cell grid. Command history reads
  a bounded range of SwiftTerm's buffer, never injects styled rows into it.
- Deny terminal-initiated clipboard reads/writes and unsafe hyperlink schemes.
- QA must not alter real profiles, credentials, history, or active Claude work.
  Use isolated app state and harmless prompts; never commit user terminal traces.

## Automated acceptance gates

| Area | Cases | Required result |
| --- | --- | --- |
| Build | clean debug and universal release, Intel + Apple Silicon, signature, dependency resources/license | Reproducible pinned build; both binaries and resource bundles included |
| VT grid | cursor moves, erase/insert/delete, wrap pending, scrolling margins, origin mode, SGR, tabs, save/restore | Exact expected cells and cursor, not only matching flattened text |
| Unicode | split UTF-8, combining marks, CJK, emoji, wide cells at right margin, box/block glyphs | Correct cell width and overwrite; no split glyphs |
| Chunking | same synthetic TUI replay whole, bytewise, and deterministic variable chunks | Identical final cells, attributes, cursor, and modes |
| Resize | 80x24 → 120x40 → 60x18 → original, repeated redraw, font zoom, sidebar/split resizing | PTY geometry matches renderer; no duplicated frames or forced reset |
| Screens/history | normal scrollback, alternate enter/leave, scroll while output streams | Normal history remains; alternate-screen scroll gestures go to application where appropriate |
| Input | arrows, modifiers, Shift+Enter, Control-C, IME path, paste with/without bracketed mode | Correct bytes; no implicit submission of bracketed paste |
| Long paste | 5 KB, 64 KB, 1 MB UTF-8 with slow PTY reader and partial writes | Exact byte count/hash; ordering preserved; no truncation |
| Selection | short range, wrapped lines, wide text, copy all, trailing cell padding | Only selected text, no unrelated history or padding |
| Remote | ANSI cell snapshot, colors, cursor, Unicode, geometry, reconnect, input | Browser displays same screen; no legacy text-model corruption |
| Integration | shell OSC titles/CWD/command boundaries, ledger, context, tabs, splits, close | Existing features work without modifying the emulator's grid |
| Security | OSC 52, non-http links, malformed/fragmented control strings | No clipboard access or unsafe external action |

Run existing `make test`, web tests, and the new Swift bridge regression suite.
Use upstream conformance tests as additional evidence, not a substitute for
TerminalDB's integration tests or real-user QA. Record unavailable tools/tests.

## Visible user-perspective QA

Use the installed candidate (isolated state for QA), not a user-launched worktree
build. Browser checks use the Codex in-app browser so Safari/user typing is not
disturbed. Do not interrupt an active terminal session to install or test.

1. Launch the app, check About/build identity, open two windows with two tabs
   each, and verify a single app icon. Use normal menus for split/zoom/sidebar.
2. Launch real Claude Code in a disposable directory with a test-safe profile.
   Inspect its welcome border/avatar at narrow, medium, and wide sizes.
3. Ask for a harmless long numbered response. Scroll back with trackpad/wheel
   while it streams, select/copy a small paragraph, then return to the prompt.
4. Type two lines with Shift+Enter; verify no submission until plain Enter.
   Paste long synthetic text, inspect its beginning/end, cancel without running
   instructions. Compare copied text outside the terminal.
5. Resize repeatedly while Claude is idle and streaming. Open/close the sidebar,
   resize a split, zoom text, switch tabs and windows. Check borders, cursor,
   prompt, no bouncing/duplicates, and no stuck output.
6. Cancel with Control-C and exit normally. Type a shell command afterward;
   verify visible prompt, echo, paste, selection, and scrollback still work.
7. Exercise `vim`, `less`, `tmux`, `fzf`, and `vttest` when installed. Check
   alternate-screen restoration and mouse/keyboard navigation. List omissions.
8. Use Remote Web through the normal button; open a tab from the device list,
   compare rendering and Unicode, type/paste, resize/reconnect, switch accounts
   per tab, and verify one-time-link access remains intact. Avoid changing auth.
9. Check command History/details, selected-text AI context, account/usage panel,
   and close controls. No additional windows for utility views, no profile loss.
10. Confirm macOS accessibility focus, keyboard-only selection/navigation, IME,
    Retina rendering, light/dark themes, and reduced-motion behavior. Record any
    manual-only gaps explicitly rather than claiming full coverage.

## Handoff gate

- Automated and visible outcomes reported separately, with failures/blockers.
- No known regression in the reported Claude flows; no account/history loss.
- PR checks green and merged to main; primary checkout updated.
- Build merged main, install `/Applications/TerminalDB.app`, safely restart,
  confirm About. Never stop active user work without permission.
- Do not tag/publish a public release without a new explicit release request.

## Execution record

Date: 2026-08-26. Source baseline: `4dcaeed` (`origin/main`). Dependency:
SwiftTerm 1.19.0, commit `464df5207fc2432e16c9a23abe538187196daf5f`.

### Automated results

- `make -C apps/macos test-ci`: passed, including 52/52 Swift surface checks,
  Objective-C integration checks, bundle signature/icon checks, secret scan,
  isolated remote-agent identity/socket tests, and Claude status hooks.
- `make -C apps/macos qa-tabs`: passed grouped windows, selected tab,
  independent shells, activity, titles, menu, assistant, and close assertions.
- `npm run test:web`: 78 tests passed across 12 files.
- `npm run build:web`: passed.
- `npm run test:web:e2e`: 146 passed, one desktop touch-target scenario skipped.
  This is automated fixture-based browser coverage, **not** a live native-to-web
  acceptance pass.
- Universal release assembly passed for arm64 and x86_64, including a second
  consecutive build. SwiftPM uses separate architecture scratch paths; resource
  bundles and the MIT license are included. Intel hardware execution is untested.
- `git diff --check`: passed.

### Visible native results

Candidate installed as `/Applications/TerminalDB SwiftTerm QA.app`, isolated
bundle identity and disposable app/profile/history state, version 0.3.0 with
build `0.3.0-swiftterm-qa`. This identifies the candidate only: the user's
installed 0.4.0 app has **not** been replaced or downgraded.

Real Claude Code 2.1.246 ran in a disposable working directory, using harmless
synthetic prompts. No real Claude profiles were removed, replaced, or signed out.

| User action | Observed result |
| --- | --- |
| Open About and launch Claude | Candidate identity confirmed; welcome borders/avatar rendered cleanly |
| Type two lines with Shift+Enter | Draft remained unsubmitted; plain Enter submitted |
| Ask for 80 numbered lines, then wheel-scroll | Earlier response lines became visible; return-to-bottom worked |
| Resize narrow/wide while scrolled | No duplicate welcome frames or broken borders |
| Exit Claude with Control-C, run a shell command | Shell prompt and input recovered; no injected EXIT/SAVED footer |
| Repeat with TerminalDB's existing classic-screen launch setting | Native scrollback worked; resized and zoomed rendering remained clean |
| Paste 6,975 UTF-8 bytes / 122 lines with Command-V | Claude showed the matching 121-newline paste marker; no implicit submission; cancel/exit worked |
| Use normal New Tab, Split Right, and History controls | Tab/split UI and in-window History opened; populated History/copy acceptance still pending |

The exact long-paste contents/ordering are established by automated byte-equality
tests at 5 KB, 64 KB, and 1 MB; the visible paste marker alone is not proof of
full-content fidelity. No user terminal traces or credential screenshots are
included in this report or the repository.

### Blocked or untested acceptance checks

- macOS switched to `loginwindow` during the final pass. Native interaction is
  paused, not worked around. Remaining checks: actual drag-select/Command-C,
  populated History/details, two windows with two tabs each, selected-text AI
  context, and utility-panel focus recovery.
- The Codex in-app browser loaded the production sign-in page, but local
  development navigation returned `ERR_BLOCKED_BY_CLIENT`. A live encrypted
  native-to-browser session has **not** been verified with this renderer.
- Complete remote rendering/input/paste/reconnect/resize and one-time-link QA
  using a disposable QA agent, never the user's active agent or real sessions.
- `vim`/`less` and third-party TUI acceptance remain pending. `tmux`, `fzf`, and
  `vttest` were not available for this pass. Physical IME, VoiceOver, light theme,
  reduced motion, and real Intel hardware checks are not claimed.
- Snapshot tests cover live cells, SGR, wide glyphs, cursor, wrap-pending,
  bracketed paste, application-cursor mode, alternate-screen entry, and a maximum
  500x200 colored viewport. Reconnect fidelity for saved cursor/charset, origin,
  insert, wrap-disable, and mouse protocols needs explicit acceptance coverage;
  do not describe these tests as full VT state serialization.

### Rollout still required

1. Finish the blocked visible checks and address any failures before marking
   the PR ready. The user's canonical app still owns an active Claude process.
2. Ship the matching web snapshot reader before installing the native migration:
   it understands the active-SGR/wrap-pending suffix and large colored grids.
   Reassembly is bounded to 2,048 chunks and 8 MiB total buffered characters.
3. Wait for required PR checks, merge main, update the primary checkout, then
   build/install with a non-downgraded version and a distinct merged-commit build
   identifier. Protect active work before quitting the canonical app.
4. Confirm the canonical installed app's About identity and perform final smoke
   QA. No version tag or public GitHub release is authorized by this task.
