# Shared AWS access

Click **AWS** in the window's footer to open **Accounts → AWS**. The footer
summarizes configured profiles on the current tab's execution Mac; AWS can have
several ready profiles at once. **Claude** opens the same pane for the tab's
Claude account. **TerminalDB → Accounts** is also available.

The pane names its execution Mac. Each workstation keeps its own AWS profile
mappings. Viewing profiles never selects `AWS_PROFILE` or changes a command's
profile. New tabs continue to open on This Mac.

## Setup

1. Pair the Macs. Open **Accounts → AWS → Sharing** on each Mac and
   enable AWS sharing with the other paired Mac. AWS sharing is separate from
   Claude sharing and is off by default.
2. On the Mac with your AWS profiles, open **Profiles**. TerminalDB detects
   supported SSO and console-login profiles in `~/.aws/config`.
3. Choose **Sign In** on the SSO session's header when AWS requires
   authentication, or **Share Access** on a profile row to share usable
   existing access. One completed official browser sign-in renews the session
   for all its local profiles. Access is published only for
   the selected profile and profiles already selected for sharing.
4. On the receiving Mac, the shared profile appears in **Profiles**. Choose
   **Use on This Mac** once. An unused profile name imports immediately. If
   the name is occupied, review the proposed alias or explicitly confirm
   replacing the matching local profile. Unrelated profiles are preserved.
5. Use the configured name in normal AWS commands or an SDK's profile
   selection. **Ready** means the shared access is usable without
   signing in again here. **From …** identifies the Mac providing the access.

Profiles are grouped by SSO session, under a header such as **COMPANY-SSO**.
A browser sign-in belongs to the session and renews every profile that uses
it, so **Sign In** is a visible button on the session header and never hidden
in a menu.

Each profile row shows the profile name, account and role, and where its
access comes from: **On This Mac**, **Shared from This Mac**, or **From**
followed by the providing Mac's name. One status line follows:

- **Ready**: the access works.
- **Not shared**: the profile is usable on this Mac and not shared with other
  Macs.
- **Access until 6:10 PM** or **Expired**: the SSO session is signed out, and
  this is how long already issued access lasts.
- **Access denied**: AWS refused the account or role.
- **Couldn't check access**: the check did not complete.
- **Can't reach AWS**: there is no connection to AWS.

A row shows one button only when there is something to do: **Share Access**,
**Use on This Mac**, **Sync Now**, **Review…**, or **Use Shared Access…**. Its
actions menu contains **Check Access** with the last checked time, **Share
This Mac's Access**, **Sign In Here…** for received profiles, **Use Another
Profile Name…**, **Copy Profile Name**, and **Remove from This Mac…**. There is
no separate Details page.

**Sharing** is a secondary page. Use **Back** at its top to return to the
profiles.

Each workstation keeps its own profile mappings. A new name does not require a
second confirmation form. A same-name migration preserves the original profile
in a private backup before installing the managed mapping; a separate alias
keeps the existing profile and its original AWS login command available.

Received profiles synchronize automatically with reachable, approved sources.
**Check Access** in a profile's actions menu can request current access.
**Sign In Here…** is an optional local login when you want this Mac to provide
renewed access itself; it is not required to consume valid shared credentials. The official AWS CLI
owns the browser authentication. Any approved Mac can provide renewed access.

Removing a managed mapping restores its original configuration when it has not
been edited independently. Stopping sharing prevents additional publication
from this Mac. These actions do not run the global `aws sso logout` command or
sign unrelated profiles out.

## SSO sessions

The session header shows one of these states:

- **Signed in until 4:34 PM**, with the time left and how many profiles the
  sign-in renews (for example, "renews 3 profiles"). The header turns orange
  when less than 30 minutes remain.
- **Signed out**, with a prominent **Sign In** button.
- **Session may have ended**, when the estimated end time has passed.
- **Signing in…**, with **Cancel**, while the browser sign-in is in progress.

AWS does not tell clients when a session ends. TerminalDB times the session
from your last sign-in using the expected session length. By default this is
AWS's standard 8 hours. If a session ends earlier than expected, TerminalDB
shortens the length automatically and marks it as measured. You can also set
it yourself with **Session Length** in the session's actions menu, from 1 hour
to 90 days, or choose **Automatic**. Match the length your AWS administrator
configured.

Signing in again during an active session does not move its end time. AWS
keeps the original end time. Choose **Extend…** in the session's actions menu
to start a new full-length session. Extend ends only that one SSO session, not
other sessions on the Mac, and opens the browser for a full sign-in. Access
already issued keeps working until it expires. **Sign In Without Ending
Session** in the same menu signs in again and keeps the current end time.

## Ready and automatic renewal

Working profiles show **Ready**. TerminalDB renews selected access in the
background through the official AWS CLI and sends updates to approved Macs.
Routine use requires no manual renewal. The source Mac must remain awake,
logged in, and able to reach AWS; receiving Macs need LAN or VPN connectivity
to a source when fresh credentials are needed.

The footer summarizes readiness and calls out sign-in or other attention when
needed. Reconnecting and stale status are shown explicitly; they never silently
fall back to the viewing Mac's profiles. Opening Accounts and drawing its footer
use cached, nonsecret status metadata rather than invoking AWS or Keychain reads.

For a remote tab, **Sign In on This Mac** completes the official browser flow
on the Mac you are using. Temporary access reaches other Macs only through
approved AWS sharing. Sharing stays a separate choice on both Macs; the sign-in
action does not grant another device permission. Remote profile changes and
checks require the current terminal controller. Browser sign-in, credential
export, and sync management remain local operations.

If the execution Mac originally shared a native profile, received credentials
alone do not change the provider its AWS commands use. When that native login
needs recovery and usable access arrives from an approved Mac, choose **Use
Shared Access…** and confirm the settings change. TerminalDB keeps a private
backup, uses the received provider for that profile, and stops renewing its old
local source. The app does not perform this migration silently or label the
native provider Ready merely because a received copy exists.

An expired cached SSO access token does not by itself require another browser
sign-in: the AWS CLI can refresh it silently. TerminalDB asks for **Sign In**
when the CLI confirms authentication is needed. Connection, permission, and
other access-check failures have their own recovery guidance. When an SSO
session has ended, TerminalDB first confirms that AWS is reachable, then shows
the session as **Signed out** with **Sign In** instead of reporting a failed
check. Existing
credentials remain usable until their actual expiry, subject to AWS
revocation. Profiles sharing an SSO session show the same browser sign-in
progress on the session header, and a cancelled sign-in does not discard
still-valid access.

**Check Access** in a profile's actions menu uses the existing AWS login or
shared access. It does not start a fresh session, extend an existing
credential, or enable sharing for an unselected profile. AWS controls the
lifetime. A valid cached credential can keep the same expiry after a
successful check. The menu shows when access was last checked.

A credential's expiry is not the session's end. While the session is signed
in, profile rows show **Ready**. When it is signed out, each row shows **Access
until** the time its already issued access expires, or **Expired**. The
session end on the header is TerminalDB's estimate, described in
[SSO sessions](#sso-sessions).

A receiving Mac shows **Ready** and the Mac providing its shared access. Its
original local SSO cache does not determine whether that shared access works,
including when a managed mapping replaces an original native SSO profile.
**Sign In Here…** stays optional in the profile's actions menu for when a
receiving Mac needs new access. Healthy profiles and connection or permission
errors do not present it as the required recovery.

Renewing SSO authentication does not enable sharing for every account or role.
Only profiles explicitly selected for sharing are published. Already-enabled
profiles in the same SSO session renew their access after browser sign-in.

## Offline use and expiry

Each receiving Mac keeps device-only Keychain copies of temporary credentials.
It can use them while the source is offline, until AWS expires them. A signed-in
Mac refreshes selected profiles and sends updated access to approved peers.
An offline sign-in synchronizes automatically when LAN or VPN returns.

If no reachable Mac can renew access, sign in on This Mac or reconnect a
signed-in Mac. TerminalDB never extends expiry or returns expired access.
Disabling sync or unpairing stops future transfers; it cannot immediately
invalidate copies already held by other Macs or processes. Revoke access in
AWS when immediate termination is required.

## Security and compatibility

TerminalDB uses AWS's documented `credential_process` interface. CLI/SDK
consumers receive temporary credentials and AWS's expiration. Existing
environment credentials and tool-specific provider precedence still apply.
There is no shell wrapper, global credential environment, static-key sync,
or copying of the entire `.aws` directory.

AWS SSO refresh tokens and console-login device keys stay local to the AWS CLI
that owns them. Only selected SSO/console-login profiles are exported. Profile
names alone are not identity: provider, account and role/principal bind the
shared record. Imported metadata cannot install arbitrary commands, endpoints,
plugins or executable paths; executable paths are chosen locally.

Secrets are bounded in memory during private mutual-TLS transfers. Persistent
catalogs contain metadata and source revisions; temporary credentials are
device-only Keychain items, excluded from iCloud Keychain. Sensitive actions
use private local IPC and installed-code identity checks. Remote terminal
requests cannot export AWS credentials.

Install a current AWS CLI v2 from AWS or Homebrew on a Mac where you sign in.
Receiving CLI/SDK consumers must support `credential_process`; AWS command-line
use also requires the AWS CLI as usual. On a receiving Mac, use **Sign In Here…**
for optional local browser authentication of a managed profile because AWS
resolves SSO before process credentials. Original sign-in settings are kept
locally for that action. Newer `aws login` device-bound material never syncs.

Profile detection supports named and legacy SSO plus AWS browser-login profiles.
Static keys, assume-role chains, arbitrary external credential processes, and web
identity profiles are not exported. Standard, user-owned `~/.aws/config` files
are supported; symlinked or unsafe configurations require manual review.

References: [external process credentials](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sourcing-external.html),
[credential export](https://docs.aws.amazon.com/cli/latest/reference/configure/export-credentials.html),
[IAM Identity Center token scope](https://docs.aws.amazon.com/singlesignon/latest/OIDCAPIReference/Welcome.html),
and [AWS session semantics](https://docs.aws.amazon.com/singlesignon/latest/userguide/authconcept.html).
