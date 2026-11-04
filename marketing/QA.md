# Marketing website QA

Run this pass on the release candidate served from `marketing/`. Keep automated
checks and browser outcomes separate. No real credentials or terminal contents
should appear in screenshots or recorded evidence.

## Automated checks

Run `python3 marketing/test_site.py`. The check validates document and heading
structure, links and section order, local assets and screenshot dimensions,
required product boundaries, generic profile copy, security headers, and
credential patterns. It does not prove visual layout, download availability, or
native functionality.

## Visible browser pass

1. At desktop widths of 1440 and 1024 pixels, open the top of the page. Confirm
   the hero has a clear title and primary download action; the native screenshot
   is readable and does not cover text. Check aligned card padding and headings
   through the workstation, Claude, AWS, usage, tools, privacy, and download areas.
2. At 768, 390, and 320 pixels, inspect the entire page. Confirm navigation wraps
   intentionally, columns stack, profile examples fit, images retain aspect ratio,
   buttons remain usable, and no text or page content creates horizontal scroll.
3. Use every header link, the logo, and footer links. Confirm each internal
   destination appears below the sticky header. Check the three download buttons
   target the same latest stable `TerminalDB-macOS.zip` asset. Follow Release notes
   and GitHub documentation links and verify the release asset is available.
4. Use only the keyboard from a fresh page load. Reveal Skip to content, activate
   it, then navigate links and FAQ summaries. Check visible focus and natural tab
   order. Open and close each FAQ using Enter or Space. No pointer-only control
   should be necessary.
5. Enable reduced motion and reload. Confirm anchor navigation does not animate.
   Disable JavaScript and repeat navigation and FAQ interaction. At 200% zoom,
   confirm text and controls remain accessible without overlapping.
6. Inspect both native screenshots at full size. Confirm they show the release
   interface and only synthetic data. Alt text should describe the visible app,
   not an obsolete layout or a long transcription of account values.
7. Read every heading, description, FAQ, and metadata summary as a first-time
   visitor. Copy uses the present tense, introduces the native terminal and its
   core tools, and explains current benefits without migration history or
   comparisons to former implementations. A new tab starts on This Mac; another
   workstation is an explicit choice; both pairing approvals and both account-sync approvals are
   clear; LAN works without internet; away access uses the user's VPN. No public
   terminal ports, browser terminals, cloud account requirement, or security
   guarantee should be implied.
8. Read the account edge cases. A reusable Claude account added away from home
   syncs on return to approved Macs. Ordinary local sign-ins need Share Sign-In.
   AWS profiles are detected generically, collisions offer aliases, and cached
   access expires unless renewed. Unpairing cannot revoke copies already issued.
9. Confirm download requirements are visible: macOS 13+, Apple Silicon (M1 or later),
   not notarized, GitHub source and checksum verification, and first-launch
   instructions. The download steps explain the one-time manual update from
   0.6.7 or earlier, away from the hero, and retain the stable ZIP URL. Do not
   imply that the app has completed Developer ID notarization.
10. With browser network inspection, reload and expand FAQ disclosures. The page
    should request only its own HTML, CSS, favicon, and two screenshots. It should
    make no analytics, font CDN, script, account, or terminal connection requests.
    External GitHub requests should occur only after following a link.

## Release evidence, November 3, 2026

Automated validation:

- Passed `python3 marketing/test_site.py` after refreshing both native captures,
  matching their 1920 × 1264 dimensions, and fixing the skip destination's focus.
- Static review confirms no scripts, external fonts, analytics, forms, embeds, or
  account endpoints. The production CSP disallows scripts, connection requests,
  frames, and form submission. This is source/header evidence, not a browser
  network-inspector result.

Visible browser and native capture outcomes:

- At 1440 and 1024 pixel desktop widths and 768, 390, and 320 pixel widths, the
  page had no horizontal overflow.
- Workstations, Claude, AWS, and Privacy header links reached their sections
  with a 104 pixel offset below the sticky header.
- All eight FAQ disclosures opened and closed using Enter.
- Skip to content transferred keyboard focus to the main landmark after adding
  its `tabindex="-1"` destination.
- The GitHub security documentation link opened successfully.
- Both product images are current native 0.6.5 screenshots at 1920 × 1264. The
  capture app used a private synthetic shell and three fictional reusable Claude
  accounts. Fictional usage/history show the current interface without a pace
  warning. No real terminal contents, account credentials, or device identities
  were captured. Screenshot URLs are versioned to replace previously cached UI.

Not executed or still pending:

- Public release asset download and availability: pending publication. All three
  download links are statically verified to target the same latest stable
  universal `TerminalDB-macOS.zip` asset.
- OS reduced-motion setting, JavaScript-disabled browsing, 200% browser zoom,
  and browser network inspection were not executed. Static CSS includes reduced
  motion handling, and the page has no JavaScript dependency, but those checks
  must not be reported as visible passes.
- Native application functionality and physical Mac/VPN scenarios are covered
  separately; this website pass does not substitute for those tests.

## Present-tense product copy review

Plan: read the introduction, privacy section, account FAQs, and page metadata as
someone encountering TerminalDB for the first time. Check that the native
terminal and its core tools lead the page, current capabilities use the present
tense, and device/account approval, VPN, expiry, and installation boundaries
remain clear. Inspect desktop and phone layouts and use the normal navigation
and revised FAQ controls.

Automated outcome:

- `python3 marketing/test_site.py` passes after updating the existing account
  boundary assertion to match the present-day account-free product description.

Visible browser outcomes:

- The introduction identifies the native terminal, command history, project
  tools, and Claude assistance. The privacy section explains direct paired-Mac
  connections over LAN or VPN. Both read without migration context.
- At 1440, 390, and 320 pixel widths, the page has no horizontal overflow. The
  hero and privacy copy wrap within their columns; Privacy navigation clears
  the sticky header.
- Both revised account FAQs open through their normal summary controls and
  display the present-tense reconnect and token-sharing explanations.
- Independent editorial review finds no past/future product narrative or
  migration framing; the security and provider boundaries remain intact.

This pass covers website copy and layout. Native application behavior and the
broader accessibility/network-inspector scenarios are unchanged and are not
claimed as newly executed here.

## Product accuracy review, November 4, 2026

Plan: compare every public claim with the current workstation, Claude account,
and AWS sharing implementation. Review changed text at desktop and phone
widths, follow AWS navigation, and open both revised FAQ disclosures through
their normal controls. Keep this pass limited to marketing copy; the installed
native release and running terminal sessions do not need replacement.

Automated outcome:

- `python3 marketing/test_site.py` and `git diff --check` pass. The existing
  credential-boundary assertion now covers temporary AWS credentials, including
  supported console-login credentials as well as SSO role credentials.

Visible browser outcomes:

- The live page matches the repository before editing. The terminal remains
  the primary product message; requirements state Apple Silicon and macOS 13+.
- In the local preview at desktop width and 390 pixels, the revised AWS section
  wraps within its columns and the AWS navigation reaches the intended section.
- The AWS and Claude sharing FAQs open through their normal disclosure controls.
  AWS describes the current Sync Now and Sign In Here actions and distinguishes
  an offline source Mac from connectivity to AWS. Claude explains restarting
  after renewal. Sharing approval and provider expiry boundaries remain clear.
- Independent source review confirms that renewing an SSO session applies to all
  local profiles using that session; publication remains limited to selected
  profiles. The privacy note includes AWS provider activity.

Native functionality, physical networking, browser network inspection, and the
broader accessibility matrix are not newly tested by this copy-only pass.

## Ready and automatic renewal copy

For 0.6.9, review AWS copy against the Ready-first native interface. Expiry and
Check Access belong in Details, renewal is automatic, and a check does not
promise eight more hours. Required sign-in follows AWS authentication failure;
sharing remains selected and source-offline use still ends at actual expiry.

- Static site validation passes with the updated copy and Ready illustration.
- Local browser review at desktop and 390-pixel widths confirms the AWS copy
  and illustration fit. AWS navigation and the updated source-offline FAQ work
  through their normal controls.
- Native interface and live provider outcomes are recorded separately in the
  AWS Ready QA pass; website review does not substitute for them.
