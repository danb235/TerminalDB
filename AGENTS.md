# TerminalDB working agreement

## Definition of done

Feature work is not complete when it exists only in a Codex worktree. Unless
the user explicitly asks to stop earlier, complete every change with this
handoff:

1. Run the relevant automated regression checks.
2. Write and execute a user-perspective QA plan through the visible macOS and
   web interfaces. Exercise the normal buttons, menus, forms, and navigation a
   user would use. Test-only commands and fixtures may supplement this pass,
   but do not substitute for it.
3. Commit the finished change on a feature branch, push it to `origin`, open a
   pull request, wait for required checks, and merge it into `main`.
4. Update the primary checkout at `/Users/danielbohannon/Projects/TerminalDB`
   to the merged `origin/main`.
5. Build the merged primary branch and install it as
   `/Applications/TerminalDB.app` with `make install`. Never ask the user to
   locate or launch a build inside `.codex/worktrees` for manual QA.
6. After protecting any active terminal work, quit old TerminalDB app and
   agent processes and open `/Applications/TerminalDB.app`. Confirm the About
   window reports the intended version before handing off manual QA.

Public releases are separate from merging. Do not push a version tag or
publish a GitHub release unless the release workflow has been explicitly
requested and approved.

## QA evidence

Report user-visible scenarios and outcomes separately from automated test
counts. For remote-account work, cover at minimum:

- creating an account from the Mac Remote Control window;
- creating an account from an active one-time-link web terminal;
- signing out and signing back in without a link;
- finding and opening the enrolled Mac's session after sign-in;
- preserving one-time-link access without an account; and
- visible failure and recovery behavior when the Mac or agent is unavailable.

Use disposable accounts and remove them after QA. Never include passwords,
TOTP secrets, pairing links, tokens, terminal contents, or enrollment codes in
logs, screenshots, commits, pull requests, or status updates.
