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

One DynamoDB on-demand table stores tenant-scoped device/session indexes,
controller public keys, single-use pairings and tickets, connection mappings,
and replay nonces. A Cognito user pool provides optional self-service accounts.
TTL
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

Remote supports two independent access grants:

- **One-time link:** the existing possession-based pairing flow works without
  an account and grants access only to the session named by the opaque link.
- **Account:** Cognito managed login uses authorization code with PKCE. API
  Gateway validates the access token, and the control Lambda derives the tenant
  exclusively from Cognito's immutable `sub` claim. A signed-in browser can
  discover and register a controller only for sessions indexed under that
  subject.

Cognito is a control-plane identity, not a terminal encryption key. An account
browser still creates non-extractable P-256 signing and ECDH keys. The Mac and
browser derive their directional content keys from ECDH plus a random
per-controller account salt. AWS sees the public keys and salt but cannot
derive the shared secret. Account controllers require both a current Cognito
access token and the registered browser signing key when minting a connection
ticket. Guest controllers continue to use the original signed ticket path.

Tenant equality is checked again when a ticket is created, when its WebSocket
connects, and before either relay direction is routed. Session IDs supplied by
clients are never treated as tenant authority. Guest pairings remain a
deliberate, separately authorized exception: possession of the single-use link
can register a guest controller for exactly one session.

Pairing links have the form `/pair/{opaqueId}#{secret}`. The fragment is removed
with `history.replaceState` after use and never reaches AWS. Pairing secrets are
random, single-use, valid for ten minutes, and stored only as salted hashes.
Connection tickets are random, single-use, valid for sixty seconds, and stored
only as SHA-256 hashes.

The browser holds non-extractable P-256 signing and key-agreement keys in
IndexedDB. OAuth tokens are stored separately and never written to DynamoDB or
application logs. The Mac holds its P-256 identity in Keychain. Pairing authenticates a
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
instead of replaying a transcript. Terminal input carries a per-tab stream
sequence, so the browser may pipeline small batches while the Mac reorders them
before PTY writes. Output frames report the highest input sequence they reflect,
allowing local prediction to reconcile without freezing the authoritative
terminal. The agent advertises this capability in inventory; during a rolling
upgrade, browsers retain the acknowledgement barrier until the Mac reports
sequence-reordering support. Side effects use short-lived request IDs and are successful only after
an application acknowledgement from the Mac. A lost acknowledgement becomes
`DELIVERY UNCERTAIN`; terminal input and account changes are never automatically
sent again.

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
websocketMessagesPerSecond=50
websocketBurst=100
lambdaReservedConcurrency=8
budgetEmail=you@example.com
domainName=remote.example.com
certificateArn=arn:aws:acm:us-east-1:...
cognitoFromEmail=verified-sender@example.com
cognitoFromName=TerminalDB
cognitoReplyTo=support@example.com
cognitoSesRegion=us-west-2
```

The CloudFront Free flat-rate plan is selected operationally after deployment
when the account is eligible. AWS does not currently expose a supported
CloudFormation/CDK or public CLI operation for pricing-plan association, so CDK
prints the required association status instead of calling an undocumented API.
Set `cloudfrontPlan=PAYG` when the account is not eligible.
