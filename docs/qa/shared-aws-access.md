# Shared AWS access QA

Use isolated installed QA apps, synthetic configurations and fake AWS CLI
executables. Never capture credentials, browser authorization URLs/codes,
device keys, or private terminal output. Fixtures supplement visible QA;
they do not prove real AWS authentication works.

## User-perspective scenarios

1. Open AWS Access. Check This Mac context, helpful empty state and separate
   Profiles / Sync Macs views. Terminal pairing or Claude approval never opts
   a Mac into AWS sharing.
2. Enable AWS sync on both QA Macs using native controls. A one-sided opt-in
   transfers no credentials and gives practical counterpart instructions.
3. Confirm existing synthetic SSO and console-login profiles appear without
   re-entering their settings. Exercise Sign In and Share Current Sign-In.
   Original source configuration stays byte-identical. Check nonsecret
   account/role/expiry information and practical expired-login recovery.
4. Use a profile on another Mac with the native button. Its process mapping
   references that Mac's installed helper. Run a harmless fixture AWS command
   through the ordinary CLI/profile path; inspect only a boolean marker.
5. Sign in on either QA Mac. Verify renewed temporary access propagates without
   a receiver login. Keep captured process output private.
6. Disconnect the source and use valid cached access. Add a selected profile
   while offline, reconnect, and verify automatic arrival. Check expiry with
   no usable source and recovery after renewal.
7. Remove through the normal confirmation. Check safe original-config restore,
   withdrawal propagation, replay denial, independent-source preservation and
   no logout of unrelated AWS profiles.
8. Disable AWS sync or revoke a disposable pairing. Verify future transfers
   stop; disabling only AWS sync preserves terminal control.
9. Repeat with physical Macs, VPN reconnect and sleep/wake where available.
   Report unavailable scenarios as pending.

## Automated coverage

Cover malformed/oversized credentials, expiry, wrong account/principal,
revision replay, missing-Keychain repair, withdrawal, independent sources,
copied-state writer rotation, metadata-only persistence, profile collisions,
comment preservation, restoration conflicts, unsafe config writes, static and
arbitrary process-profile denial, local code identity, remote export denial,
separate two-sided AWS approval, and real-agent recovery.

## Execution record

Automated: `make test-ci` passed 96 surface checks, native product self-tests,
302 native peer checks (including 59 AWS store, 50 configuration and 66 AWS
service checks), 23 persistent-session integration checks, and bundle/icon,
secret and Claude-hook checks. The actual native-agent AWS suite passed 19
scenarios; the existing peer/account integration suite passed 28. The AWS suite
uses only synthetic credentials and a fake CLI, not AWS services.

Visible: two isolated apps installed in Applications on one physical Mac passed
normal menu navigation, explicit native pairing approvals on both interfaces
with private fingerprint comparison, AWS-off-after-pairing, two-sided AWS
checkbox approval with immediate save, and retained settings after switching
views. Detected SSO and console-login profiles required no re-entered settings.
The native Sign In and Share Current Sign-In actions produced usable synthetic
access without changing either public source configuration. The window names
the actual Mac, profile rows stay compact, and receiving setup requires one
explicit Use on This Mac confirmation.

A harmless fixture AWS command was entered in the receiving native terminal
through its normal profile/credential-process path while the source networking
helper was suspended; its private success marker passed. A new profile added
while disconnected stayed local, then appeared automatically after reconnect.
Native removal restored original configuration. Sign-in progress and Cancel
were exercised; regression tests additionally cover no delayed enrollment after
cancellation and renewal/sign-in races. Temporary fixture identities were
re-paired after a deliberate ephemeral-key restart; production trust was never
changed for these tests.

Pending: real AWS browser authorization, physical multi-Mac AWS transfer, and
physical VPN/sleep recovery specifically for AWS sharing. Earlier terminal and
Claude physical acceptance is not substituted for these scenarios. No real
AWS profile, credential or sync approval was changed during this QA pass.
Universal arm64/x86_64 release build passed. Merged-primary installation/About
results are recorded during handoff. No release tag or public release is part
of this change.
