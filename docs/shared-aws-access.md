# Shared AWS access

Open **TerminalDB → AWS Access** to make selected AWS SSO and console-login
profiles available on your approved Macs over the LAN or VPN. This panel
manages commands run on **This Mac**; each workstation keeps its own mappings.

## Setup

1. Pair the Macs normally. In AWS Access → Sync Macs, enable AWS sync on both
   ends. AWS sharing is independent of Claude sharing and off by default.
   Selected Macs also exchange profiles received from their other approved Macs.
2. TerminalDB detects existing SSO and console-login profiles in `~/.aws/config`.
   Choose Sign In beside a profile, or Share Current Sign-In to reuse an already
   valid login. TerminalDB chooses the correct official AWS login flow. Your
   existing source profile and its command-line name stay unchanged.
3. On another approved Mac, choose Use on This Mac once. Existing name
   conflicts require approval; unrelated profiles are preserved.
4. Choose Sign In on This Mac when necessary. The official AWS CLI opens the
   browser and owns authentication. Any Mac can provide renewed access; there
   is no permanent coordinating Mac.

When using a received profile, keep its familiar name or choose another name
in the one-time setup. A same-name receiving profile uses TerminalDB's Sign In
button for future browser authentication; choosing a separate name preserves
its original login command as well. No profile name needs to be re-entered
for ordinary sign-in.

Original receiving profile configuration is backed up before migration. Remove stops
publishing this Mac's selected access and restores its managed mapping when
the configuration has not been edited independently. Removal never runs the
global `aws sso logout` command or signs unrelated profiles out.

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

Consumers must support `credential_process`. A managed same-name profile uses
TerminalDB's Sign In action rather than `aws sso login --profile name`, because
AWS resolves SSO before process credentials. Original sign-in settings are kept
locally for that action. Newer `aws login` device-bound material never syncs.

References: [external process credentials](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sourcing-external.html),
[credential export](https://docs.aws.amazon.com/cli/latest/reference/configure/export-credentials.html),
[IAM Identity Center token scope](https://docs.aws.amazon.com/singlesignon/latest/OIDCAPIReference/Welcome.html),
and [AWS session semantics](https://docs.aws.amazon.com/singlesignon/latest/userguide/authconcept.html).
