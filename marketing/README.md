# TerminalDB marketing site

This folder is the complete static marketing site. It is deliberately isolated
from the native macOS application so website changes do not rebuild or release
the app.

## Local preview

```sh
cd marketing
python3 -m http.server 4173
```

Then open `http://127.0.0.1:4173`.

## Validation

```sh
python3 marketing/test_site.py
```

The checks cover local assets, internal anchors, screenshot dimensions,
accessibility text, release links, accidental credentials, personal data, and
Claude Design preview artifacts.

## Product screenshots

The hero and Claude account sections use real native TerminalDB captures:

* `uploads/terminaldb-native-current.png`
* `uploads/terminaldb-accounts-current.png`

Both captures come from the app's isolated visual QA mode. The accounts, paths,
hosts, usage values, and reset times are fictional fixtures. Refresh the
captures whenever the relevant native interface changes.

## Deployment

The site is ready for Cloudflare Pages with `marketing` as the asset directory.
The dedicated site workflow is separate from App CI. Configure the repository
variable `CLOUDFLARE_PAGES_PROJECT` and the secrets
`CLOUDFLARE_ACCOUNT_ID` and `CLOUDFLARE_API_TOKEN` to enable deployment.

The intended first project name is `terminaldb`. A custom domain can be added
later without changing the site.

The account indicator loads the dedicated status bridge at
`https://app.terminaldb.app/auth-status.html`. The bridge accepts requests only
from the TerminalDB marketing origins and returns a signed-in boolean plus the
Cognito username. Tokens remain in the app origin and are never shared with
the marketing site.

## Design provenance

The page was designed in the TerminalDB Claude Design project and exported as a
static source artifact. `support.js` is the generated interaction runtime.
React and ReactDOM are vendored so the site does not depend on a third party
runtime CDN.
