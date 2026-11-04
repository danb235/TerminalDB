# Apple Silicon release QA

## Scope

TerminalDB 0.6.8 (17) supports Apple Silicon Macs (M1 or later) running macOS 13
or later. Intel support is removed. Do not run Intel slices through Rosetta.
Keep existing historical universal-build evidence in its original QA records.

## Automated plan

- Run `make test` and `make test-ci`, plus the marketing-site tests.
- Build a release and verify the GUI, session host and networking helper each
  contain exactly `arm64`, retain the macOS 13 minimum, and pass bundle signature
  verification. Verify no other bundled Mach-O file introduces an Intel slice.
- Verify the updater accepts an Apple Silicon package and rejects Intel,
  universal, unknown, malformed and missing-helper packages before installation.
- Verify CI builds on an Apple Silicon runner and publishes both the versioned
  arm64 ZIP and the existing stable download alias with matching checksums.
- Download the public artifact, verify its checksum, version, architecture and
  stable signing identity independently of the local build.

## Visible user plan

1. Open the marketing site. Confirm Apple Silicon / M1-or-later and macOS 13+
   requirements are clear and all download buttons lead to the stable asset.
   Check the release notes explain the one-time manual upgrade from older apps.
2. Protect active work, install the verified public app in Applications and open
   it normally on each of the three available Apple Silicon Macs. Open About
   from the application menu and confirm 0.6.8 (17).
3. Open AWS Access through the native menu on each Mac. Confirm existing
   profiles, sharing, providing-Mac labels and ready states remain available.
   Reopen the window to confirm the same state persists. Do not sign in again.
4. Verify both existing sibling AWS profiles resolve the expected account/role
   on all three Macs, recording only pass/fail metadata. Check ordinary terminal
   input using a dedicated harmless command without capturing terminal contents.
5. Inspect Applications and background registrations for old QA installations;
   remove only known TerminalDB QA artifacts. Preserve private backups and the
   user's other applications and settings.

## Boundaries

Report visible outcomes separately from automated counts. Architecture checks
establish that the package has no Intel/Rosetta requirement; they do not prove
compatibility with unreleased macOS versions or quantify runtime performance.
Older in-app updaters reject an arm64-only package, so upgrading from 0.6.7 or
earlier requires one manual replacement. Future updates use the new verifier.
This release does not change pairing or network transport; earlier physical
LAN/VPN/pairing evidence remains separate from this distribution pass.

## Candidate evidence

Visible website QA: the normal first-launch notice link opens the download
section. The hero and download section both identify Apple Silicon / M1 or
later and macOS 13+. The download section keeps the manual-upgrade guidance
beside the installation steps, with aligned columns and readable spacing.
All three download links retain the stable GitHub asset URL. This pass uses
the local candidate site; the deployed page is checked separately after merge.

Automated candidate results: `make test` and `make test-ci` both pass, including
96 terminal-surface checks, 744 AWS interface/layout checks, 547 native
peer/service/configuration checks and 23 persistent-session checks. Updater
self-tests cover exact architecture parsing, all three required executables,
missing components, linked files/directories and stable-asset checksum selection.
Signature, icon, secret, background-tab and Claude hook checks pass. Marketing
structure, accessibility, product-boundary and download checks pass. The build
and workflow shell/YAML checks pass, including rejection of an unsupported
Intel build target before compilation; no Intel code is executed.

Read-only pre-upgrade provider checks confirm the expected account and role for
both existing sibling profiles on all three physical Macs: six successful STS
checks without another browser sign-in. The inventory finds no recognized old
TerminalDB QA app, LaunchAgent file or loaded launch label on any of them.
Background-item database inspection passes on the MacBook Pro; macOS denies
that read on the other two Macs, so their database inspection remains pending.
Installed 0.6.8 About, normal terminal input, deployed-site and public-artifact
checks remain part of the post-merge handoff and are reported separately.
