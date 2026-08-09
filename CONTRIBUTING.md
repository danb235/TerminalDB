# Contributing to TerminalDB

TerminalDB is an early stage native macOS project. Bug reports, focused fixes,
tests, documentation improvements, and carefully scoped feature proposals are
welcome.

## Before you start

1. Read the [architecture guide](docs/architecture.md), the
   [threat model](docs/threat-model.md), and the [roadmap](docs/roadmap.md).
2. Search existing issues before opening a new one.
3. For a large behavior or UI change, open an issue before writing the patch so
   the approach can be discussed.
4. Never put API keys, Claude credentials, terminal history, private paths, or
   customer data in an issue, fixture, screenshot, or commit.

## Local setup

TerminalDB requires macOS 13 or later and the command line developer tools.

```sh
git clone https://github.com/danb235/TerminalDB.git
cd TerminalDB
make test
```

See [docs/build.md](docs/build.md) for build details and
[docs/testing.md](docs/testing.md) for the complete test matrix.

## Pull requests

Keep pull requests small enough to review confidently. A pull request should:

- explain the user problem and the chosen behavior
- include tests for new behavior and important failure modes
- preserve the local first privacy model
- avoid unrelated formatting or refactoring
- update documentation and `CHANGELOG.md` when behavior changes
- pass `make test-ci` and the marketing site tests

Run these checks before pushing:

```sh
make test-ci
python3 marketing/test_site.py
git diff --check
```

Automated checks are necessary but are not the user-acceptance pass. Before a
feature PR is merged, write down its main user journeys and exercise them
through the visible macOS and web interfaces. Record what a user did and saw,
including recovery states; do not treat test-only commands or mocked fixtures
as proof that the shipped workflow works.

Completed work should be pushed on a branch, reviewed in a pull request, and
merged into `main`. For local manual QA, update the primary checkout and run:

```sh
make install
open /Applications/TerminalDB.app
```

This builds the universal app from the checked-out commit and installs the
canonical QA copy. Do not hand off an app bundle inside a development
worktree.

The app and marketing site have separate CI paths. Application changes are
validated by App CI. Files under `marketing/` are validated and deployed by Site
CI.

## Code style

The native application is Objective C using AppKit and Foundation without a
third party package manager. Match the surrounding style:

- four space indentation
- explicit, descriptive names
- small methods with visible error handling
- nullability on public interfaces
- no hidden network or filesystem behavior

Use `apply_patch` or a normal editor for changes. Generated build products do
not belong in source control.

## Security reports

Do not open a public issue for a vulnerability involving credential exposure,
command execution, history disclosure, update integrity, or sandbox escape.
Follow [SECURITY.md](SECURITY.md) instead.

## License

By contributing, you agree that your contribution is licensed under the MIT
License in [LICENSE](LICENSE).
