# Shared AWS access

Open **TerminalDB → AWS Access** to make selected AWS SSO and console-login
profiles available on your approved Macs over the LAN or VPN. This panel
manages commands run on **This Mac**; each workstation keeps its own mappings.

## Setup

1. Pair the Macs. Open **TerminalDB → AWS Access → Sharing** on each Mac and
   enable AWS sharing with the other paired Mac. AWS sharing is separate from
   Claude sharing and is off by default.
2. On the Mac with your AWS profiles, open **Profiles**. TerminalDB detects
   supported SSO and console-login profiles in `~/.aws/config`.
3. Choose **Sign In** when the SSO session needs renewal, or **Share Access**
   to reuse a valid existing login. One completed official browser sign-in
   renews the session for all its local profiles. Access is published only for
   the selected profile and profiles already selected for sharing.
4. On the receiving Mac, the shared profile appears in **Profiles**. Choose
   **Use on This Mac** once. An unused profile name imports immediately. If
   the name is occupied, review the proposed alias or explicitly confirm
   replacing the matching local profile. Unrelated profiles are preserved.
5. Use the configured name in normal AWS commands or an SDK's profile
   selection. **Ready on This Mac** means the shared access is usable without
   signing in again here. **From …** identifies the Mac providing the access.

**Share Access**, **Use on This Mac**, and the sign-in action are visible on the
profile row. The overflow menu contains additional management actions.

Each workstation keeps its own profile mappings. A new name does not require a
second confirmation form. A same-name migration preserves the original profile
in a private backup before installing the managed mapping; a separate alias
keeps the existing profile and its original AWS login command available.

Use **Sync Now** on a receiving Mac to request current shared access. It needs
a reachable, approved source with access to share. **Sign In Here** is an
optional local login when you want this Mac to provide renewed access itself;
it is not required to consume valid shared credentials. The official AWS CLI
owns the browser authentication. Any approved Mac can provide renewed access.

Removing a managed mapping restores its original configuration when it has not
been edited independently. Stopping sharing prevents additional publication
from this Mac. These actions do not run the global `aws sso logout` command or
sign unrelated profiles out.

## Sign-in status

A profile using this Mac's own AWS login shows its SSO session's cached
authentication status separately from its temporary account/role access. **SSO needs renewal**
or **SSO sign-in needed** can appear while cached profile access is still usable.
**Sign In** stays visible; **Sign In Again** renews a current session without a
terminal command. Profiles sharing that session show the same browser sign-in
progress. A cancelled or failed sign-in keeps existing cached access but does not
claim a renewed SSO login.

Status reflects the local AWS CLI token cache, not a guarantee that AWS has not
revoked access. An unreadable or unsafe cache shows **SSO status unavailable**.
A receiving Mac with valid shared access shows **Ready on This Mac** and its
providing Mac. An
expired or missing local SSO cache does not produce a mandatory renewal warning
for that shared access, including when the receiving profile replaces an
original native SSO profile. Its shared credential expiry remains visible.
**Sign In Here** remains optional; **Sync Now** requests renewal from the
approved source.

On a Mac providing access, **Refresh Access** requests renewed role credentials
using its existing login. **Sign In Again** is available separately when a new
browser sign-in is needed.

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
use also requires the AWS CLI as usual. On a receiving Mac, use **Sign In Here**
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
