# TerminalDB QA audit

Audit date: 2026-07-24  
Reference: Claude Design project `TerminalDB command ledger`, all 19 routes  
Build: native AppKit application, ad-hoc development signature

## Release verdict

The audited build is suitable for continued alpha testing. Core terminal,
Claude API, account, command-ledger, permission, history, and persistence
paths pass the automated and live smoke tests below.

The application is **not yet at 100% pixel parity** with the exhaustive design
prototype. The main terminal, AI pane, command inspector, history, API
settings, account status, and usage surfaces use the Graphite Ledger language.
Project Tools, Environments, Monitor Center, Runbooks, Workspaces, Settings,
and Onboarding remain function-first native list/detail implementations rather
than the dedicated layouts in the design. Structured historical commands also
live in the ledger header, History, and Inspector instead of every prior
command being rendered as an inline selectable terminal block.

## Executed test matrix

| Area | Adversarial scenarios | Result |
| --- | --- | --- |
| Build | Clean compile with `-Wall -Wextra`; no warnings | Pass |
| Runtime safety | AddressSanitizer and UndefinedBehaviorSanitizer self-test | Pass |
| Bundle | Designated bundle identifier and code-signature verification | Pass |
| App icon | Bundle metadata plus all 10 iconset representations from 16px through 1024px | Pass |
| Secrets | Full working-tree scan for Anthropic key patterns | Pass |
| Live Anthropic API | Authenticated Models request; 10 models; streamed Messages request using selected `claude-sonnet-5`; delta and stop events | Pass |
| Terminal parser | ANSI, 256/truecolor, cursor visibility, split UTF-8, C1 handling, alternate screen, prompt cursor | Pass |
| Terminal input | Control-C, Space, Return, arrows, F1, plain paste, bracketed paste | Pass |
| Scroll behavior | Output following, manual scroll, input return-to-bottom, multi-megabyte bounded scrollback | Pass |
| Tabs | Independent PTYs, grouped tabs, selected tab, activity indicator, shell and Claude lifecycle titles, close cleanup | Pass |
| Splits | Right/down creation, independent shell state, workspace snapshot tree | Pass |
| AI composer | Focus, ongoing transcript, New Chat, missing-key guidance and recovery | Pass |
| AI rendering | Streaming transcript, multiple command cards, adjacent Paste/Run actions, unified-diff actions | Pass |
| Explicit context | Visible block context and terminal-selection attachment | Pass |
| Inspections | Read-only allowlist, blocked mutations, timeout/output shape, transcript integration | Pass |
| Directory boundary | `..`, absolute paths, shell expansion, globs, and symbolic-link escape attempts | Pass |
| Permissions | Read-only, unknown, write, destructive, remote, and production classification; absolute tools, runbooks, redirects, `find -delete`, and `git -C ... reset --hard` | Pass |
| History privacy | Redaction for Anthropic, GitHub, Slack, AWS, bearer/basic auth, quoted secrets, and flags; private sessions | Pass |
| Persistence | Malformed JSON/type sanitization; 0600 files and 0700 support directory | Pass |
| Models | Malformed cached model filtering, selected model, refresh, key removal clearing stale models | Pass |
| SSE | Fragmented events and final unterminated event flush | Pass |
| Claude profiles | Invalid/path-traversal identifiers, unlimited profiles, isolated runtime files, removal | Pass |
| Usage | 0–100 clamping, stale/unavailable labeling, future reset rollover, 5h/7d/Fable display | Pass |
| Runbooks | Empty/comment-only rejection, create/edit/run count/delete, multi-step parsing | Pass |
| Workspaces | Snapshot, rename, delete, tabs, splits, model, account/chat state | Pass |
| Monitoring | Start/finish/stall shape, bounded 500-item stress run | Pass |
| Menus | Exact top-level order; required application, shell, edit, view, AI, history, window, and help actions; dynamic account/model state | Pass |
| Window matrix | Main, API Settings, Usage, History, Inspector, Project, Environments, Monitor, Runbooks, Workspaces, Settings, Onboarding | Pass for opening, sizing, and clipping |
| QA isolation | Repeated tab and product tests leave command history and product state byte-for-byte unchanged | Pass |

## Design route parity

| Design route | Functional parity | Visual parity | Notes |
| --- | --- | --- | --- |
| Foundation | N/A | Pass | Tokens, typography, and signal colors are implemented. |
| Block anatomy | Partial | Partial | Latest/live block has actions and metadata; prior commands are not all inline blocks. |
| App icon | Pass | Pass | Distinctive prompt-and-ledger icon ships in the bundle at required sizes. |
| Menus | Pass | Native | Correct macOS menu hierarchy and dynamic states; native rendering is intentional. |
| Accessibility | Partial | Partial | Labels, focus, keyboard access, contrast, and reduced-motion hooks exist; full VoiceOver audit remains. |
| Status & usage | Pass | Near | Active account, plan, profiles, refresh, 5h/7d/Fable, and resets are present. |
| Main terminal | Pass | Near | Core layout is close; historical inline block stack is incomplete. |
| AI pane states | Partial | Near | Conversation, stream, errors, context, commands, and settings work; not every prototype state has a dedicated presentation. |
| Failure flow | Partial | Partial | Explain/Fix and permissioned retry work; the six-step visual journey is not reproduced as a dedicated view. |
| Command inspector | Pass | Near | Metadata, output, actions, export, and bookmark work. |
| History database | Pass | Near | Search, filters, bookmarks, saved searches, export, and clearing work. |
| Project tools | Partial | No | Git/file/test actions exist; dedicated tree, diff, and hunk-review layout differs. |
| Environments | Partial | No | Detection and safety policy exist; dedicated SSH/Kubernetes/production layouts differ. |
| Monitor center | Partial | No | Lifecycle, stall, output, jump/stop, and summary context exist; dedicated cards differ. |
| Runbooks | Partial | No | CRUD, parsing, permissioned run/paste, and persistence exist; editor/execution layouts differ. |
| Workspaces | Partial | No | Save/restore tabs, splits, context, rename/delete work; browser/layout-preview views differ. |
| Onboarding | Partial | No | The eight designed semantic steps exist; current presentation is list/detail rather than a wizard. |
| Settings | Partial | No | All 12 categories are present; many are guidance/action rows rather than complete inline controls. |
| Sheets & dialogs | Partial | Native | Critical confirmations exist as native sheets/alerts; the complete gallery and typed-clear flow are not implemented. |

## Defects corrected during this audit

- Prevented synthetic QA commands from entering the user's command history.
- Isolated runbook/workspace/monitor tests from the real product database.
- Removed stale cached models when the API key is removed.
- Sanitized malformed saved models, profiles, ledger records, and product state.
- Hardened destructive-command detection across absolute paths, runbooks,
  redirects, `find -delete`, `git -C`, and privileged commands.
- Blocked read-only inspection from escaping through symbolic links or
  symlink-following flags.
- Expanded secret redaction and preserved quote delimiters.
- Bounded terminal scrollback and monitor retention under stress.
- Rolled stale reset timestamps forward and labeled cached/unavailable usage.
- Added account switching/removal to the Usage window.
- Corrected onboarding step mapping and navigation labels.
- Fixed minimum sizes and autoresizing for History, Inspector, Usage, and
  product windows.
- Expanded menus and implemented the newly exposed actions.

## Remaining release risks

1. Dedicated workflow/settings/onboarding layouts must be rebuilt to reach
   pixel parity with the prototype.
2. The terminal needs an inline block model for every historical command to
   fully realize the core design.
3. Project Tools needs a real file tree, dedicated unified/split diff views,
   and per-hunk approve/reject UI.
4. Monitor Center needs interactive-prompt supervision and notification
   controls matching the design.
5. Accessibility needs a manual VoiceOver, Full Keyboard Access, Increase
   Contrast, Reduce Motion, and large-text pass.
6. The development build is ad-hoc signed and not notarized.

## Repeat locally

```sh
make test
```

For memory and undefined-behavior coverage:

```sh
mkdir -p /tmp/terminaldb-sanitize
clang -fobjc-arc -Wall -Wextra -fsanitize=address,undefined \
  -framework AppKit -framework Foundation \
  src/main.m src/ClaudeAPI.m src/ClaudeAssistantView.m \
  src/TerminalInspector.m src/ClaudeProfile.m src/ClaudeStatusBar.m \
  src/TerminalTheme.m src/TerminalLedger.m src/TerminalPermissions.m \
  src/TerminalProduct.m -o /tmp/terminaldb-sanitize/TerminalDB
ASAN_OPTIONS=halt_on_error=1:detect_leaks=0 \
UBSAN_OPTIONS=halt_on_error=1 \
  /tmp/terminaldb-sanitize/TerminalDB --self-test
```
