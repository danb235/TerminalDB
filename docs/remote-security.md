# TerminalDB Remote security and abuse controls

## Trust boundaries

- AWS is an untrusted ciphertext router.
- Cognito authenticates optional user accounts; API Gateway validates account
  JWTs before account routes reach the Lambda.
- IAM can mint operator enrollment codes. A signed-in Cognito user can mint a
  short-lived enrollment code bound to that user's immutable `sub` claim.
- Registered Macs and paired controllers sign control requests with P-256.
- Account controllers require both a current Cognito access token and their
  registered non-exportable P-256 key to mint WebSocket tickets.
- WebSocket upgrades consume one-time tickets atomically.
- The Mac remains the authority for PTY input, Claude account switching,
  foreground-process checks, request deduplication, revocation, and session end.

No repository, CDK output, environment file, browser URL, application log, or DynamoDB item
contains a private key, Claude credential, account token, pairing plaintext, or
terminal plaintext. The open-source reference stack uses AWS-owned encryption
for DynamoDB and S3; end-to-end content encryption does not depend on an
AWS-held key.

## Abuse controls

- No anonymous Mac registration. Enrollment is either IAM-authorized or bound
  to an API-Gateway-verified Cognito subject.
- Account session discovery queries only `USER#{sub}` records, where `sub`
  comes from the verified token and never from a request body or URL.
- Account tenant equality is rechecked during controller registration, ticket
  issuance, WebSocket connect, Mac key lookup, and relay routing.
- Cognito self-signup requires email verification, uses a 12-character strong
  password policy, suppresses user-existence errors, requires TOTP MFA, and
  enables Cognito threat protection in enforced mode.
- At most five active account enrollment codes per user.
- At most three active pairing links and five trusted controllers per Mac
  session.
- Ten-minute pairing TTL and sixty-second ticket TTL.
- Rolling 24-hour TTL for active control-plane records, renewed by connection
  tickets, with seven-day TTL cleanup after session end or revocation.
- One-time HTTP request nonces and signed timestamps with a sixty-second skew.
- 30 KB relay payload cap and one API Gateway billing unit target.
- WebSocket stage rate/burst throttles and low Lambda reserved concurrency.
- WAF managed core, known-bad-input, IP-reputation, API rate, and socket rate
  rules.
- Session, generation, role, destination, expiry, and controller trust checks
  before `PostToConnection`.
- `$5` and `$15` monthly budgets, relay and DynamoDB alarms, and an emergency
  `disableNewPairings` CDK context switch.

The browser uses a strict content security policy, HSTS, no-referrer policy,
frame denial, limited permissions policy, no third-party analytics, and a
service worker that never caches pairing paths, API responses, or socket
traffic.

## Logging policy

Lambda application code must not log event payloads. API access logs are
allowlisted to request ID, method/route, status, and response length. WebSocket
query strings are omitted. CloudFront viewer logging and S3 access logging are
off because URL paths can contain short-lived pairing identifiers.

Before a production release, run:

```sh
npm ci
npm run build
npm test
npm run test:web:e2e
npm run test:cost
npm audit --omit=dev --audit-level=high
npm run cdk:synth
make test-ci
```

Review `cdk-nag` acknowledgements in `infra/cdk/lib/remote-stack.ts`. They are
limited to runtime-generated WebSocket/log-stream suffixes, the CDK static
deployment provider, privacy-motivated logging omissions, and the default
CloudFront certificate in development. Production should provide a custom
domain and ACM certificate.
