# TerminalDB Remote v1 architecture

TerminalDB Remote is a ciphertext relay. Terminal content, Claude transcripts,
account credentials, usage responses, scrollback, and command history remain on
the Mac. AWS stores only short-lived routing and trust metadata.

## Request path

```text
Phone browser ── HTTPS/WSS ── CloudFront + WAF ──┬── private S3 web origin
                                                 ├── HTTP API → control Lambda
                                                 └── WebSocket API
                                                      ├── connection Lambda
                                                      └── relay Lambda
                                                              │
                                               PostToConnection ciphertext
                                                              │
                                              TerminalDBRemoteAgent on the Mac
```

One DynamoDB on-demand table stores devices, controller public keys, sessions,
single-use pairings and tickets, connection mappings, and replay nonces. TTL
removes ephemeral records and point-in-time recovery protects the trust graph.
There is no VPC, NAT gateway, queue, IoT Core resource, KMS customer key,
Secrets Manager secret, transcript bucket, or always-on compute.

CloudFront rewrites `/socket` to the selected WebSocket API stage, so browsers
use one public origin. API access logs contain request ID, route, status, and
response length only. Query strings, request bodies, response bodies, IP
addresses, user agents, terminal data, and identifiers are omitted. Viewer and
S3 access logs are intentionally disabled because pairing IDs are path
components.

## Protocol and encryption

Pairing links have the form `/pair/{opaqueId}#{secret}`. The fragment is removed
with `history.replaceState` after use and never reaches AWS. Pairing secrets are
random, single-use, valid for ten minutes, and stored only as salted hashes.
Connection tickets are random, single-use, valid for sixty seconds, and stored
only as SHA-256 hashes.

The browser holds non-extractable P-256 signing and key-agreement keys in
IndexedDB. The Mac holds its P-256 identity in Keychain. Pairing authenticates a
P-256 ECDH exchange; HKDF-SHA256 creates separate AES-256-GCM keys for each
direction. Text is optionally level-1 DEFLATE-compressed before encryption.
Every authenticated metadata field is AES-GCM additional data.

Each wire envelope is below 30,000 bytes and includes:

- protocol version, opaque route, session generation, and optional destination;
- sequence and request IDs;
- sent and expiry timestamps;
- compression marker, unique 96-bit nonce, and ciphertext.

The relay validates only metadata and forwards the original bytes. It never
decrypts or logs the payload.

## Delivery and reconnection

PTY output is at-most-once. Sequence gaps request a fresh current viewport
instead of replaying a transcript. Side effects use a short-lived request ID and
are successful only after an application acknowledgement from the Mac. A lost
acknowledgement becomes `DELIVERY UNCERTAIN`; terminal input and account changes
are never automatically sent again.

The browser reconnects with full jitter around 0.5, 1, 2, 4, 8, 15, and 30
seconds and retries immediately on focus, visibility return, `pageshow`, and the
browser online hint. The last safe viewport stays visible. Routine resync,
relay reordering recovery, and socket rotation remain in the background and do
not blur the terminal. Input disables only when the transport or Mac is no
longer usable; drafts remain in page memory. Initial `LIVE` still requires
current Mac health and a fresh inventory/viewport.

API Gateway closes WebSocket connections after two hours. At 110 minutes the
client opens a fresh ticket and socket, promotes it before closing the old
socket, keeps the old socket for a 30-second grace period, and resynchronizes.

## CDK layout

`infra/cdk` synthesizes two stacks:

- `TerminalDBRemote-{stage}-Edge` in `us-east-1` for the CloudFront-scoped WAF;
- `TerminalDBRemote-{stage}` in the configured application region.

Useful context:

```text
stage=dev|prod
region=us-west-2
cloudfrontPlan=FREE|PAYG
disableNewPairings=true|false
websocketMessagesPerSecond=25
websocketBurst=50
lambdaReservedConcurrency=8
budgetEmail=you@example.com
domainName=remote.example.com
certificateArn=arn:aws:acm:us-east-1:...
```

The CloudFront Free flat-rate plan is selected operationally after deployment
when the account is eligible. AWS does not currently expose a supported
CloudFormation/CDK or public CLI operation for pricing-plan association, so CDK
prints the required association status instead of calling an undocumented API.
Set `cloudfrontPlan=PAYG` when the account is not eligible.
