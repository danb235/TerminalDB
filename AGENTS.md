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
counts. For native peer work, cover pairing approval on both Macs, fingerprint
mismatch, unpaired denial, revocation, new and existing sessions, multiple
viewers and takeover, app exits, network recovery, offline LAN, configured
internet endpoints, and forwarding through a third paired Mac. Exercise the
normal native controls. Report unavailable physical or network scenarios as
pending; automated fixtures do not substitute for them.

Never include passwords, TOTP secrets, pairing material, tokens, terminal
contents, or enrollment codes in logs, screenshots, commits, pull requests,
or status updates. Preserve active legacy sessions during upgrades.
