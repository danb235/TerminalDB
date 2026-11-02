# Local typing and recovered backpressure

## Failure and fix

Ordinary local typing became laggy and Return stopped working behind Review
Input. A local socket write-pressure timeout weakly captured its write source.
After normal recovery, both that source and the active writer became nil; the
identity comparison then matched and closed a healthy connection ten seconds
later. Interrupted input acknowledgements correctly paused typing, but later
state messages incorrectly replaced the warning with READY.

Require a live, matching write source before applying the stall timeout. Keep
the existing timeout for genuinely blocked readers. Keep INPUT PAUSED visible
until the user reviews uncertain input; never replay it. Session-host profiling
also showed account forecast/history rebuilding on the 200 ms terminal-state
poll. Cache those entries for at most one second, invalidating immediately for
account-result or profile-list changes. Selected-account labels and sign-in
state remain immediate; explicit refresh invalidates the cache.

## Automated plan and evidence

- A real socketpair with a 4 KiB send buffer forces write pressure. Resume its
  reader, wait past the original timeout and exchange another message. This
  regression failed on the old code: the recovered connection was closed.
- The same regression passes with the fix. A separate reader that never drains
  still reaches its write deadline and closes. Three transport checks were added.
- Run surface, protocol/security, persistent-host, real-agent and product checks.
  Check that account refresh/sign-out updates are not hidden by the forecast cache.
- The patch-revert fixture tolerates a file's brief absence during atomic git
  apply publication; other errors still fail the test.
- A synthetic two-profile benchmark with 4096 history samples per profile and
  100 state publications took 3862.27 ms before caching and 57.15 ms after it.
  Both versions produced all six forecasts. These measure account-status work,
  not keyboard-to-display latency.

## Visible QA plan

Use an installed isolated native candidate, synthetic files and its actual
session helper. Preserve production work and never record terminal contents,
credentials, keys or pairing material.

1. Type l, s and Return separately. Verify the shell completes the command.
2. Produce a large output burst, let buffers drain, wait beyond ten seconds,
   then type another command. Require the same controller generation and session,
   no Review Input, and exact completion of a synthetic marker command.
3. Briefly suspend only the disposable QA host while entering a synthetic marker
   command. Wait for input to expire, resume the host and confirm INPUT PAUSED
   remains visible through later state updates. The marker must not be created.
4. Use Review Input and I Have Reviewed It. Confirm ordinary typing resumes on
   the same shell and the expired command is not replayed.
5. Verify the merged installed app's About version and local keyboard behavior.
   Measure host responsiveness with the user's configured account history, and
   distinguish those timings from full keyboard-to-display latency.

Record final automated and visible outcomes in the PR handoff. Stop no active
user shells to apply the session-host update without explicit authorization.
