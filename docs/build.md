# Build guide

## Requirements

- An Apple Silicon Mac (M1 or later) running macOS 13 or later
- Xcode command line tools
- Swift 6.2 or newer, `clang`, `make`, `codesign`, and `lipo`
- `zsh` for the embedded interactive shell
- Python 3 for marketing site tests

Claude Code is optional. It is required only when using a Claude subscription
as the AI provider. An Anthropic API key can be used instead.

## Development build

```sh
make
open apps/macos/build/TerminalDB.app
```

`make` builds the Objective C sources directly with `clang`, assembles the app
bundle, copies resources, and applies an ad hoc signature with the
`com.terminaldb.app` identifier.

To rebuild and launch:

```sh
make clean
make run
```

## Apple Silicon release build

```sh
./apps/macos/Scripts/build-app.sh release
```

The release script builds an `arm64` app and bundled helpers for Apple Silicon
Macs (M1 or later). The version and build default to `Info.plist`; release
automation supplies the published version and build. When the
`TerminalDB Self-Signed` identity exists in the login Keychain it is used so
releases have a stable signing identity. Otherwise the build is ad hoc signed.

The current release process does not notarize the application.

## Canonical local QA install

After a feature branch has been reviewed and merged, update the primary
checkout and install the merged app in the standard macOS location:

```sh
git switch main
git pull --ff-only origin main
make install
open /Applications/TerminalDB.app
```

`make install` creates an Apple Silicon release build, verifies its signature, and
replaces `/Applications/TerminalDB.app`. It refuses to replace a running copy;
save active terminal work and quit the installed app first. The bundle version
comes from `apps/macos/Info.plist`, so the About window can be used to confirm
which local QA build is open.

## Updating from 0.6.7 or earlier

These versions need a one-time manual update because their in-app updater
requires a universal bundle. Use the current Apple Silicon download directly;
there is no intermediate update to install.

1. Finish and save active terminal work before replacing the app and session host.
2. Download [`TerminalDB-macOS.zip`](https://github.com/danb235/TerminalDB/releases/latest/download/TerminalDB-macOS.zip)
   and unzip it.
3. Quit TerminalDB and replace `/Applications/TerminalDB.app` with the downloaded app.
4. Open TerminalDB and confirm the intended version in **TerminalDB → About TerminalDB**.
   In-app updates work from the new version.

The current download requires an Apple Silicon Mac (M1 or later) and macOS 13
or later. The stable download name stays `TerminalDB-macOS.zip`.

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
`CFBundleShortVersionString` from the release tag. `CFBundleVersion` uses the
higher of the declared build and GitHub Actions run number.

Tags matching `v*` run `.github/workflows/release.yml`, which tests, builds,
signs, packages, checksums, and publishes the application.

SwiftPM resolves pinned dependencies on the first build. The app bundles the
session and peer helper apps in Contents/Library/LoginItems. Each helper has its
own bundle and signing identifier. Development
bundles launch helpers directly; the canonical /Applications/TerminalDB.app
registers them through SMAppService.loginItem. Legacy LaunchAgent definitions are
retained only to retire stopped 0.6.0 services without stopping a live host.
Dependency licenses ship in
Contents/Resources/Licenses.

The pinned SwiftTerm 1.19.0 dependency needs two small reviewed additions for
session recovery: a read-only display-state export and bounded recording of an
unfinished control-sequence prefix. `prepare-terminal-package.sh` applies these
to the package scratch directory. It verifies the original source hashes and
fails the build if upstream files change. It never changes terminal parsing
decisions. When updating SwiftTerm, review both additions and run the surface
recovery tests before changing the expected hashes. No dependency checkout is
committed or edited by hand.
