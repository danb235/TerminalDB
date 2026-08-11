# Roadmap

TerminalDB is an alpha project. Roadmap items describe intent, not a support or
delivery promise.

## Current foundation

- structured command blocks with directory, host, status, duration, and time
- searchable local command history and bookmarks
- explicit AI context chips
- Paste and permission reviewed Run actions
- Explain and Fix flows for command failures
- Anthropic API key and Claude subscription providers
- isolated management for multiple Claude subscription accounts
- usage display for session, weekly, and model specific limits
- playbooks, workspaces, environments, monitors, splits, and private sessions
- universal macOS build, checksums, and GitHub release automation

## Near term

1. Expand updater rollback and interruption tests.
2. Improve terminal emulation compatibility and accessibility.
3. Add retention controls and export for the command database.
4. Improve project tool diffs, test presentation, and reversible changes.
5. Extend long running command supervision and notifications.
6. Add more adversarial QA fixtures for remote and production environments.

## Later

- team shared playbooks with inspectable local execution
- optional encrypted history storage
- additional shells after command boundary parity is proven
- Apple Developer ID signing and notarization when program access exists
- extension points for additional AI providers
- documented stable data migration and plugin interfaces

## Design principles

- terminal work is the primary object, not chat
- context is explicit and removable
- execution is permission based and reversible where possible
- active environment and active Claude account are always visible
- local history and credential boundaries are understandable
- no artificial limit on Claude subscription profiles
