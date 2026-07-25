# Build guide

## Requirements

- macOS 13 or later
- Xcode command line tools
- `clang`, `make`, `codesign`, and `lipo`
- `zsh` for the embedded interactive shell
- Python 3 for marketing site tests

Claude Code is optional. It is required only when using a Claude subscription
as the AI provider. An Anthropic API key can be used instead.

## Development build

```sh
make
open build/TerminalDB.app
```

`make` builds the Objective C sources directly with `clang`, assembles the app
bundle, copies resources, and applies an ad hoc signature with the
`com.terminaldb.app` identifier.

To rebuild and launch:

```sh
make clean
make run
```

## Universal release build

```sh
TERMINALDB_VERSION=0.1.0 \
TERMINALDB_BUILD=1 \
./Scripts/build-app.sh release
```

The release script builds a universal `arm64` and `x86_64` binary. When the
`TerminalDB Self-Signed` identity exists in the login Keychain it is used so
releases have a stable signing identity. Otherwise the build is ad hoc signed.

The current release process does not notarize the application.

## Marketing site

The static marketing site lives in `marketing/` and has no package installation
step.

```sh
python3 marketing/test_site.py
python3 -m http.server 8080 --directory marketing
```

Open `http://localhost:8080` to inspect it locally.

## Versioning

`Info.plist` contains the development version. Release builds override
`CFBundleShortVersionString` and `CFBundleVersion` from the release tag and
GitHub Actions run number.

Tags matching `v*` run `.github/workflows/release.yml`, which tests, builds,
signs, packages, checksums, and publishes the application.
