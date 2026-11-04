# TerminalDB marketing site

This folder is the complete static marketing site. Website changes are isolated
from native app builds and releases. The page needs no JavaScript, framework,
external font, analytics, account bridge, or terminal connectivity endpoint.
Native HTML disclosures provide the FAQ interaction; all navigation and download
links work without scripts.

## Preview and validation

```sh
cd marketing
python3 -m http.server 4173
```

Open `http://127.0.0.1:4173`. From the repository root, run:

```sh
python3 marketing/test_site.py
```

The checks cover semantic structure, keyboard entry points, anchor destinations,
local assets, actual PNG dimensions, stable download links, product boundaries,
privacy headers, accidental credentials, and user-specific data. They supplement
the [visible website QA plan](QA.md); they do not replace a browser pass.

## Product copy

Write for a first-time visitor in the present tense. Lead with the native
terminal, command history, project tools, and Claude assistance. Describe what
people can do today; omit migration history, former implementations, release
announcements, and comparisons to unfamiliar alternatives.

Workstation connections are direct over a LAN or an existing VPN. Pairing
is bilateral, and Claude and AWS sharing each require separate bilateral
approval. Keep the distinction between ordinary local Claude sign-ins and shared
reusable sign-ins. AWS shares selected temporary credentials, never a promise of
access after expiry or a copy of all AWS login/refresh state. Profile names are
generic examples; identity and conflict handling must work for anyone's profiles.

New tabs start locally. Execution stays on the selected workstation, which must
remain awake and logged in. Session continuity does not survive session-host
failure, logout, or reboot. Do not claim universal connectivity, provider
endorsement, automatic file synchronization, or absolute security.

All download buttons use the latest stable `TerminalDB-macOS.zip` GitHub asset.
The current build requires an Apple Silicon Mac (M1 or later) running macOS 13
or later and is not
notarized. Keep that installation caveat visible near the primary download and
in the installation instructions until the release process changes.

Keep the one-time manual update from 0.6.7 and earlier in the download/install
instructions, separate from the hero. Those versions' updaters expect a
universal bundle and cannot install the current Apple Silicon app. Do not
introduce an intermediate download or change the stable URL.

## Product screenshots

The hero and Claude account sections use native TerminalDB captures:

- `uploads/terminaldb-native-current.png`
- `uploads/terminaldb-accounts-current.png`

Use the app's isolated visual-QA mode. Accounts, paths, hosts, usage, and reset
times must be fictional fixtures. Never capture real terminal contents, identity
fingerprints, account identifiers, tokens, passwords, or pairing material. Refresh
the captures when the native interface changes, and update each image's width,
height, and alternative text. The test reads the PNG dimensions directly.

The AWS profile card is a labeled illustration, not a screenshot or interactive
account form. It does not collect credentials or simulate an actual sign-in.

## Deployment

The current public site is [terminaldb.pages.dev](https://terminaldb.pages.dev/).
The custom domain is not configured; custom-domain setup is separate from this
website update, and no DNS changes are included.

Cloudflare Pages serves `marketing` as its asset directory through the dedicated
site workflow. Configure repository variable `CLOUDFLARE_PAGES_PROJECT` and the
secrets `CLOUDFLARE_ACCOUNT_ID` and `CLOUDFLARE_API_TOKEN`. Deploying this static
site does not create terminal infrastructure or change native device trust.

`_headers` blocks script execution, network requests, embeds, and form submission.
CSS and screenshots use short revalidation caching so a release can replace the
stable asset names without leaving the previous interface cached for a week.

## Design

The page keeps TerminalDB's Graphite Ledger palette: graphite surfaces, cyan
context, lime availability, restrained borders, and native system typography.
Semantic HTML and local CSS support the layout, with native app screenshots
as the visual source of truth.
