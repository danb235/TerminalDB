---
name: release
description: >-
  Cut and publish a TerminalDB release. Curate the user facing changes since
  the previous tag, update CHANGELOG.md, and push the version tag that triggers
  the GitHub release workflow.
argument-hint: "[<x.y.z> | patch | minor | major]"
---

# Release TerminalDB

A pushed `vX.Y.Z` tag triggers `.github/workflows/release.yml`. The workflow
runs the full test suite, builds one universal macOS application containing
Apple Silicon and Intel architectures, signs it with the stable self signed
identity when configured, verifies the bundle, creates versioned and stable
ZIP files, and publishes a GitHub release.

The first public release is `v0.1.0` and is published as a prerelease.

## 1. Check preconditions

Stop with a clear explanation if any condition fails:

- The current branch is `main`.
- `git status --porcelain` is empty.
- `git fetch origin` succeeds.
- Local `main` matches `origin/main`.
- `gh auth status` succeeds.
- `make test` passes.
- `./Scripts/build-app.sh release` produces a universal binary containing
  `arm64` and `x86_64`.

Never tag a broken, dirty, or divergent working tree.

## 2. Gather every change

Find the most recent tag with:

```sh
git describe --tags --abbrev=0
```

For the first release, inspect the complete history. Otherwise inspect:

```sh
git log --no-merges --pretty='- %s (%h)' LAST_TAG..HEAD
git diff --stat LAST_TAG..HEAD
```

Read the `Unreleased` section of `CHANGELOG.md` and reconcile it against the
commits so no user facing change is missed.

## 3. Select the version

Use Semantic Versioning:

- `major` for incompatible behavior.
- `minor` for new user facing capabilities.
- `patch` for fixes, documentation, and internal changes.

An explicit version or bump keyword wins. With no existing tag, default to the
already approved first public version, `0.1.0`.

## 4. Curate the changelog

Group notes under Added, Changed, Fixed, Removed, and Security. Remove empty
groups. Describe user impact, merge duplicate entries, and omit internal churn.

Replace:

```text
## [Unreleased]
```

with a fresh empty Unreleased section followed by:

```text
## [X.Y.Z] - YYYY-MM-DD
```

The header must retain that exact structure because the release workflow
extracts it for the GitHub release notes.

## 5. Preview and obtain approval

Show:

- The proposed version.
- The complete release notes.
- The changelog diff.
- A clear statement that continuing pushes a public tag and publishes a public
  GitHub release.

Wait for explicit approval before publishing.

## 6. Publish

After approval:

```sh
git add CHANGELOG.md
git commit -m "release: vX.Y.Z"
git push origin main
git tag -a vX.Y.Z -m "TerminalDB vX.Y.Z"
git push origin vX.Y.Z
```

## 7. Verify

Find and follow the release run:

```sh
gh run list --workflow=Release --limit 1
gh run watch RUN_ID --exit-status
```

On success, verify:

- The release is visible publicly.
- The versioned universal ZIP exists.
- `TerminalDB-macOS.zip` resolves from the latest release URL.
- The checksum file exists.
- The downloaded bundle contains both architectures.

On failure, report the failing step with:

```sh
gh run view RUN_ID --log-failed
```

Fix forward. Do not move or overwrite an already published tag.
