import { createHash, createPublicKey, randomBytes, timingSafeEqual, verify } from "node:crypto";

import {
  DynamoDBClient,
  type AttributeValue,
} from "@aws-sdk/client-dynamodb";
import {
  DynamoDBDocumentClient,
  GetCommand,
  PutCommand,
} from "@aws-sdk/lib-dynamodb";
import type { APIGatewayProxyEventV2, APIGatewayProxyStructuredResultV2 } from "aws-lambda";

export const tableName = process.env.TABLE_NAME ?? "";
export const dynamo = DynamoDBDocumentClient.from(new DynamoDBClient({}), {
  marshallOptions: { removeUndefinedValues: true },
});

export const nowSeconds = (): number => Math.floor(Date.now() / 1_000);
export const randomSecret = (bytes = 32): string => randomBytes(bytes).toString("base64url");
export const sha256 = (value: string): string =>
  createHash("sha256").update(value, "utf8").digest("base64url");
export const saltedHash = (salt: string, value: string): string => sha256(`${salt}.${value}`);

export function constantEqual(left: string, right: string): boolean {
  const leftBytes = Buffer.from(left);
  const rightBytes = Buffer.from(right);
  return leftBytes.length === rightBytes.length && timingSafeEqual(leftBytes, rightBytes);
}

export function accountTenantMatches(input: {
  readonly controllerOwnerSub: unknown;
  readonly sessionOwnerSub: unknown;
  readonly assertedOwnerSub: unknown;
}): boolean {
  return (
    typeof input.controllerOwnerSub === "string" &&
    input.controllerOwnerSub.length > 0 &&
    input.controllerOwnerSub === input.sessionOwnerSub &&
    input.controllerOwnerSub === input.assertedOwnerSub
  );
}

export function verifyP256Signature(
  publicJwk: JsonWebKey,
  message: string,
  signature: string,
): boolean {
  const key = createPublicKey({
    key: publicJwk as import("node:crypto").JsonWebKey,
    format: "jwk",
  });
  const signatureBytes = Buffer.from(signature, "base64url");
  return signatureBytes.length === 64
    ? verify(
        "sha256",
        Buffer.from(message, "utf8"),
        { key, dsaEncoding: "ieee-p1363" },
        signatureBytes,
      )
    : verify("sha256", Buffer.from(message, "utf8"), key, signatureBytes);
}

export function json(
  statusCode: number,
  body: Record<string, unknown>,
  headers: Record<string, string> = {},
): APIGatewayProxyStructuredResultV2 {
  return {
    statusCode,
    headers: {
      "content-type": "application/json",
      "cache-control": "no-store",
      ...headers,
    },
    body: JSON.stringify(body),
  };
}

export function parseBody(event: APIGatewayProxyEventV2): Record<string, unknown> {
  if (!event.body) return {};
  const decoded = event.isBase64Encoded
    ? Buffer.from(event.body, "base64").toString("utf8")
    : event.body;
  const parsed = JSON.parse(decoded) as unknown;
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new TypeError("Body must be a JSON object");
  }
  return parsed as Record<string, unknown>;
}

export async function verifyAuthenticatedRequest(
  event: APIGatewayProxyEventV2,
): Promise<{ principalId: string; principal: Record<string, unknown> }> {
  const headers = Object.fromEntries(
    Object.entries(event.headers).map(([key, value]) => [key.toLowerCase(), value]),
  );
  const principalId = headers["x-terminaldb-principal"];
  const timestamp = headers["x-terminaldb-timestamp"];
  const nonce = headers["x-terminaldb-nonce"];
  const signature = headers["x-terminaldb-signature"];
  if (!principalId || !timestamp || !nonce || !signature) throw new Error("Authentication required");
  const timestampMs = Number(timestamp);
  if (!Number.isFinite(timestampMs) || Math.abs(Date.now() - timestampMs) > 60_000) {
    throw new Error("Stale authentication");
  }
  const controller = await dynamo.send(
    new GetCommand({ TableName: tableName, Key: { PK: `CONTROLLER#${principalId}`, SK: "META" } }),
  );
  const device = controller.Item
    ? undefined
    : await dynamo.send(
        new GetCommand({ TableName: tableName, Key: { PK: `DEVICE#${principalId}`, SK: "META" } }),
      );
  const principal = (controller.Item ?? device?.Item) as Record<string, unknown> | undefined;
  if (
    !principal ||
    principal.revokedAt ||
    (principal.ttl !== undefined && Number(principal.ttl) <= nowSeconds())
  ) {
    throw new Error("Unknown or revoked principal");
  }

  const body = event.body ?? "";
  const canonical = [
    event.requestContext.http.method.toUpperCase(),
    event.rawPath,
    timestamp,
    nonce,
    sha256(body),
  ].join("\n");
  const publicJwk = principal.signingPublicKey as JsonWebKey | undefined;
  if (!publicJwk) throw new Error("Principal has no signing key");
  const valid = verifyP256Signature(publicJwk, canonical, signature);
  if (!valid) throw new Error("Invalid request signature");

  // Store a nonce only after authenticating it. This prevents unauthenticated
  // callers from turning arbitrary invalid signatures into DynamoDB writes.
  await dynamo.send(
    new PutCommand({
      TableName: tableName,
      Item: {
        PK: `NONCE#${principalId}`,
        SK: nonce,
        ttl: nowSeconds() + 120,
      },
      ConditionExpression: "attribute_not_exists(PK)",
    }),
  );
  return { principalId, principal };
}

export function stringField(body: Record<string, unknown>, name: string, maximum = 512): string {
  const value = body[name];
  if (typeof value !== "string" || value.length === 0 || value.length > maximum) {
    throw new TypeError(`Invalid ${name}`);
  }
  return value;
}

export function jsonWebKeyField(body: Record<string, unknown>, name: string): JsonWebKey {
  const value = body[name];
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new TypeError(`Invalid ${name}`);
  }
  const key = value as JsonWebKey;
  if (key.kty !== "EC" || key.crv !== "P-256" || !key.x || !key.y) {
    throw new TypeError(`${name} must be a P-256 public key`);
  }
  return key;
}

export type DynamoAttributeMap = Record<string, AttributeValue>;
