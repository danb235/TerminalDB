import {
  ApiGatewayManagementApiClient,
  GoneException,
  PostToConnectionCommand,
} from "@aws-sdk/client-apigatewaymanagementapi";
import {
  DeleteCommand,
  GetCommand,
} from "@aws-sdk/lib-dynamodb";
import type { APIGatewayProxyResultV2 } from "aws-lambda";

import { accountTenantMatches, dynamo, tableName } from "./common.js";

const MAX_WIRE_BYTES = 30_000;
const ROUTES = new Set([
  "inventory",
  "viewport.snapshot",
  "pty.output",
  "pty.input",
  "pty.resize",
  "tab.create",
  "tab.select",
  "tab.close",
  "claude.state",
  "account.inventory",
  "account.switch",
  "account.bootstrap",
  "account.bootstrap.ready",
  "usage.refresh",
  "session.end",
  "session.ended",
  "usage.snapshot",
  "ack",
  "error",
  "presence",
  "resync.request",
  "health.ping",
  "health.pong",
]);

interface RelayEvent {
  readonly body?: string | null;
  readonly isBase64Encoded?: boolean;
  readonly requestContext: {
    readonly connectionId: string;
    readonly domainName: string;
    readonly stage: string;
  };
}

interface EnvelopeMetadata {
  readonly version?: unknown;
  readonly route?: unknown;
  readonly sessionId?: unknown;
  readonly sourceId?: unknown;
  readonly destinationId?: unknown;
  readonly generation?: unknown;
  readonly sequence?: unknown;
  readonly requestId?: unknown;
  readonly sentAt?: unknown;
  readonly expiresAt?: unknown;
  readonly compression?: unknown;
  readonly nonce?: unknown;
  readonly ciphertext?: unknown;
}

function validEnvelope(candidate: EnvelopeMetadata): boolean {
  return (
    candidate.version === 1 &&
    typeof candidate.route === "string" &&
    ROUTES.has(candidate.route) &&
    typeof candidate.sessionId === "string" &&
    candidate.sessionId.length >= 16 &&
    candidate.sessionId.length <= 128 &&
    Number.isSafeInteger(candidate.generation) &&
    Number(candidate.generation) >= 0 &&
    Number.isSafeInteger(candidate.sequence) &&
    Number(candidate.sequence) >= 0 &&
    typeof candidate.requestId === "string" &&
    candidate.requestId.length >= 16 &&
    candidate.requestId.length <= 128 &&
    Number.isSafeInteger(candidate.sentAt) &&
    Number.isSafeInteger(candidate.expiresAt) &&
    Number(candidate.expiresAt) >= Date.now() - 1_000 &&
    Number(candidate.expiresAt) <= Date.now() + 60_000 &&
    ["none", "deflate"].includes(String(candidate.compression)) &&
    typeof candidate.nonce === "string" &&
    candidate.nonce.length >= 16 &&
    candidate.nonce.length <= 32 &&
    typeof candidate.ciphertext === "string" &&
    candidate.ciphertext.length > 0
  );
}

async function deleteStaleDestination(
  sessionId: string,
  role: string,
  clientId: string,
  connectionId: string,
): Promise<void> {
  try {
    await dynamo.send(
      new DeleteCommand({
        TableName: tableName,
        Key: { PK: `SESSION#${sessionId}`, SK: `SOCKET#${role}#${clientId}` },
        ConditionExpression: "connectionId = :connectionId",
        ExpressionAttributeValues: { ":connectionId": connectionId },
      }),
    );
  } catch {
    // A replacement socket may already own the mapping.
  }
}

export async function handler(event: RelayEvent): Promise<APIGatewayProxyResultV2> {
  const connectionId = event.requestContext.connectionId;
  const body = event.isBase64Encoded && event.body
    ? Buffer.from(event.body, "base64").toString("utf8")
    : event.body;
  if (!body || Buffer.byteLength(body, "utf8") > MAX_WIRE_BYTES) return { statusCode: 413 };
  let envelope: EnvelopeMetadata;
  try {
    envelope = JSON.parse(body) as EnvelopeMetadata;
  } catch {
    return { statusCode: 400 };
  }
  if (!validEnvelope(envelope)) return { statusCode: 400 };

  const sourceResult = await dynamo.send(
    new GetCommand({
      TableName: tableName,
      Key: { PK: `CONNECTION#${connectionId}`, SK: "META" },
      ConsistentRead: true,
    }),
  );
  const source = sourceResult.Item;
  if (!source) return { statusCode: 401 };
  if (
    envelope.sessionId !== source.sessionId ||
    envelope.sourceId !== source.clientId ||
    Number(envelope.generation) !== Number(source.generation)
  ) {
    return { statusCode: 403 };
  }
  const sessionId = String(source.sessionId);
  const session = await dynamo.send(
    new GetCommand({
      TableName: tableName,
      Key: { PK: `SESSION#${sessionId}`, SK: "META" },
      ConsistentRead: true,
    }),
  );
  if (
    !session.Item ||
    session.Item.status !== "active" ||
    Number(session.Item.ttl) <= Math.floor(Date.now() / 1_000) ||
    Number(session.Item.generation) !== Number(source.generation)
  ) {
    return { statusCode: 410 };
  }

  let destinationRole: "mac" | "controller";
  let destinationId: string;
  if (source.role === "controller") {
    const controller = await dynamo.send(
      new GetCommand({
        TableName: tableName,
        Key: { PK: `CONTROLLER#${String(source.clientId)}`, SK: "META" },
        ConsistentRead: true,
      }),
    );
    if (
      !controller.Item ||
      controller.Item.sessionId !== sessionId ||
      controller.Item.revokedAt ||
      Number(controller.Item.ttl) <= Math.floor(Date.now() / 1_000)
    ) {
      return { statusCode: 403 };
    }
    if (controller.Item.accessMode === "account") {
      if (!accountTenantMatches({
        controllerOwnerSub: controller.Item.ownerSub,
        sessionOwnerSub: session.Item.ownerSub,
        assertedOwnerSub: source.ownerSub,
      })) {
        return { statusCode: 403 };
      }
    } else if (source.ownerSub) {
      return { statusCode: 403 };
    }
    destinationRole = "mac";
    destinationId = String(session.Item.deviceId);
    if (envelope.destinationId && envelope.destinationId !== destinationId) return { statusCode: 403 };
  } else if (source.role === "mac") {
    destinationRole = "controller";
    if (typeof envelope.destinationId !== "string") return { statusCode: 400 };
    destinationId = envelope.destinationId;
    const controller = await dynamo.send(
      new GetCommand({
        TableName: tableName,
        Key: { PK: `CONTROLLER#${destinationId}`, SK: "META" },
        ConsistentRead: true,
      }),
    );
    if (
      !controller.Item ||
      controller.Item.sessionId !== sessionId ||
      controller.Item.revokedAt ||
      Number(controller.Item.ttl) <= Math.floor(Date.now() / 1_000)
    ) {
      return { statusCode: 403 };
    }
    if (
      controller.Item.accessMode === "account" &&
      !accountTenantMatches({
        controllerOwnerSub: controller.Item.ownerSub,
        sessionOwnerSub: session.Item.ownerSub,
        assertedOwnerSub: session.Item.ownerSub,
      })
    ) {
      return { statusCode: 403 };
    }
  } else {
    return { statusCode: 403 };
  }

  const destination = await dynamo.send(
    new GetCommand({
      TableName: tableName,
      Key: {
        PK: `SESSION#${sessionId}`,
        SK: `SOCKET#${destinationRole}#${destinationId}`,
      },
      ConsistentRead: true,
    }),
  );
  if (!destination.Item) return { statusCode: 202 };
  const destinationConnectionId = String(destination.Item.connectionId);
  const endpoint = `https://${event.requestContext.domainName}/${event.requestContext.stage}`;
  const api = new ApiGatewayManagementApiClient({ endpoint });
  try {
    await api.send(
      new PostToConnectionCommand({
        ConnectionId: destinationConnectionId,
        Data: Buffer.from(body, "utf8"),
      }),
    );
  } catch (error) {
    if (
      error instanceof GoneException ||
      (typeof error === "object" && error !== null && "$metadata" in error &&
        (error as { $metadata?: { httpStatusCode?: number } }).$metadata?.httpStatusCode === 410)
    ) {
      await deleteStaleDestination(
        sessionId,
        destinationRole,
        destinationId,
        destinationConnectionId,
      );
      return { statusCode: 202 };
    }
    throw error;
  }
  return { statusCode: 200 };
}
