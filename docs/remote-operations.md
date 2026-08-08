# TerminalDB Remote deployment and operations

## Deploy the development stack

Prerequisites are Node 24, npm, AWS CLI v2, CDK bootstrap in `us-west-2` and
`us-east-1`, and an AWS profile with deployment permissions.

```sh
npm ci
npm run build
npm run cdk:synth
npm run cdk:deploy -- --profile stelao -c stage=dev -c region=us-west-2
```

CDK prints the web URL, control Lambda name, alert topic, and enrollment
command. Before the first deploy, copy
`infra/cdk/terminaldb-remote.local.example.json` to
`infra/cdk/terminaldb-remote.local.json` and set `budgetEmail`. The local file is
gitignored, is loaded by every synth/diff/deploy, and prevents a later command
from accidentally removing the subscription because its context was omitted.
An explicit `-c budgetEmail=...` still overrides the local value. Confirm the
SNS subscription email after deployment.

When `cloudfrontPlan=FREE`, open the deployed distribution in CloudFront and
associate the Free flat-rate plan if the account is eligible. This final
association is manual because there is no supported public
CloudFormation/CDK/PricingPlanManager API for it. With no association the same
stack operates as pay-as-you-go. Do this immediately after the first deployment:
until the plan is associated, CloudFront and the attached WAF use pay-as-you-go
pricing and the deployment does not yet meet the personal sub-$1 monthly target.

The stack always creates the encrypted SNS alert topic and both budgets. Without
`budgetEmail`, no human subscriber receives those notifications.

## Open the remote app

With the reference stack deployed and the `stelao` AWS CLI profile available,
open **TerminalDB → Remote Control…** and click **Open Remote Web App**.
TerminalDB performs enrollment, starts the local agent, creates a one-time
pairing link, and opens the mirrored session in the Mac's default browser. If
Safari is the default browser, Safari is the expected destination. The web app
redeems the link automatically and removes its secret fragment from the
address bar before showing the terminal.

Click **Pair a Phone** instead to display the same single-use flow as a QR code
and copyable link. Use **Advanced Setup…** only for a custom deployment or when
the configured AWS CLI profile is unavailable.

The reference defaults are configurable through macOS preferences:

- `TerminalDBRemoteBaseURL`
- `TerminalDBRemoteAWSProfile`
- `TerminalDBRemoteAWSRegion`
- `TerminalDBRemoteEnrollmentFunction`

## Manual Mac enrollment

Create the first one-time enrollment code through the IAM-protected Lambda
invoke path:

```sh
npm run remote:enrollment -- --profile stelao --stage dev
```

The plaintext code appears once and expires in 15 minutes. The Lambda retains
only a salted hash. Enter it under **Advanced Setup…** in TerminalDB's Remote
Control window on the target Mac.

## Emergency controls

Disable only new pairings while leaving existing local work untouched:

```sh
npm run cdk:deploy -- --profile stelao \
  -c stage=dev \
  -c region=us-west-2 \
  -c disableNewPairings=true
```

For suspected controller compromise, revoke the controller from TerminalDB.
For device compromise, disable Remote Control on the Mac, which ends the cloud
session and increments the generation. Rotate the local device identity before
re-enrolling.

## Cloud record lifecycle

Active session, device-session, and controller records have a rolling 24-hour
TTL. Every successful Mac or controller connection-ticket request renews that
TTL, so a live or reconnecting installation does not expire. If a client is
terminated before it can send the normal signed session-end request, DynamoDB
eventually removes the abandoned records without retaining terminal content.

Normal session end and controller revocation mark records inactive immediately
and retain only the control-plane metadata for seven days before TTL cleanup.
Temporary device identities created by the live QA harness also expire after
seven days. Pairing and ticket records keep their shorter ten-minute and
sixty-second TTLs. DynamoDB TTL deletion is asynchronous; authorization always
checks status and expiry rather than relying on physical deletion.

## Cost checks

`packages/test-harness` computes API Gateway billing units from captured wire
sizes and fails if a foreground session sustains more than five batches per
second. Run it with:

```sh
npm run test:cost
```

The default personal caps are 25 WebSocket messages/second, burst 50, and eight
concurrent invocations per Lambda. Lower these for an especially strict
personal installation; raise them only after load and cost capture.

Run `npm audit --omit=dev --audit-level=high` before each deployment. Treat this
as the production dependency gate. Also review the unfiltered audit separately:
CDK is a build/deployment tool, and advisories in its bundled development-only
dependencies may require an upstream CDK release rather than a runtime change.
Keep CDK, `cdk-nag`, and Constructs pinned and review upgrades deliberately.

## Live encrypted-path QA

After building the native app, run the automated encrypted-session audit:

```sh
npm run live:session -w @terminaldb/test-harness
```

It creates a fresh IAM enrollment, launches the real native agent with an
ephemeral identity, pairs a non-exportable test controller, and verifies the
deployed CloudFront/WebSocket path. The audit covers protocol mismatch and
pairing replay rejection, encrypted inventory and viewport resync, terminal
input, account switching, usage refresh, lost-ack resolution without duplicate
execution, trusted-controller listing, replacement pairing, revocation, and
blocked reconnect. It accelerates one native rotation and also verifies
controller make-before-break mapping before the old socket disconnects.
Pairing secrets stay in a `0600` temporary file and the
ephemeral identity, socket, event capture, and pairing file are removed during
shutdown. The harness gives the native agent time to complete its signed
session-end request before terminating the process.

Run the deployed React client through the same native/AWS path with a real
headless browser:

```sh
npm run live:browser -w @terminaldb/test-harness
```

This browser audit consumes a fresh pairing link, verifies that its fragment is
removed, checks non-extractable IndexedDB keys, drives terminal input and Claude
account controls through the UI, accelerates a make-before-break browser socket
rotation, forces an offline/reconnect cycle, proves an unsent draft is retained
without execution, reloads the controller identity, and revokes it. It never
prints or retains the pairing URL.

For an interactive manual pass, use:

```sh
npm run live:mac -w @terminaldb/test-harness
```

Open the protected pairing-file path it prints, exercise the phone interface,
then stop the harness with Ctrl-C.

## Teardown

First disable Remote Control on the Mac and revoke controllers. Then remove the
development stacks:

```sh
cd infra/cdk
npx cdk destroy TerminalDBRemote-dev --profile stelao \
  -c stage=dev -c region=us-west-2
npx cdk destroy TerminalDBRemote-dev-Edge --profile stelao \
  -c stage=dev -c region=us-west-2
```

The development bucket and table are destroyable. Production resources use
retention, table deletion protection, and require an explicit data-retention
decision before removal. Cancel the CloudFront pricing plan separately if one
was associated.
