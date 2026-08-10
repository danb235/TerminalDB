import {
  DeleteCommand,
  GetCommand,
  PutCommand,
  TransactWriteCommand,
  UpdateCommand,
} from "@aws-sdk/lib-dynamodb";
import type {
  APIGatewayAuthorizerResult,
  APIGatewayProxyResultV2,
} from "aws-lambda";

import { accountTenantMatches, dynamo, nowSeconds, sha256, tableName } from "./common.js";

interface WebSocketRequestContext {
  readonly connectionId: string;
  readonly eventType?: "CONNECT" | "DISCONNECT" | "MESSAGE";
  readonly routeKey?: string;
  readonly domainName?: string;
  readonly stage?: string;
  readonly authorizer?: Record<string, unknown>;
}

interface WebSocketEvent {
  readonly type?: string;
  readonly methodArn?: string;
  readonly queryStringParameters?: Record<string, string | undefined> | null;
  readonly requestContext: WebSocketRequestContext;
}

function policy(
  principalId: string,
  effect: "Allow" | "Deny",
  resource: string,
  context: Record<string, string | number> = {},
): APIGatewayAuthorizerResult {
  return {
    principalId,
    policyDocument: {
      Version: "2012-10-17",
      Statement: [{ Action: "execute-api:Invoke", Effect: effect, Resource: resource }],
    },
    context,
  };
}

async function authorize(event: WebSocketEvent): Promise<APIGatewayAuthorizerResult> {
  const ticket = event.queryStringParameters?.ticket;
  const resource = event.methodArn ?? "*";
  if (!ticket || ticket.length > 256) return policy("rejected", "Deny", resource);
  const consumed = await dynamo.send(
    new DeleteCommand({
      TableName: tableName,
      Key: { PK: `TICKET#${sha256(ticket)}`, SK: "META" },
      ReturnValues: "ALL_OLD",
    }),
  );
  const item = consumed.Attributes;
  if (!item || Number(item.expiresAt) <= nowSeconds()) return policy("rejected", "Deny", resource);
  return policy(String(item.clientId), "Allow", resource, {
    sessionId: String(item.sessionId),
    role: String(item.role),
    clientId: String(item.clientId),
    generation: Number(item.generation),
    ownerSub: typeof item.ownerSub === "string" ? item.ownerSub : "",
  });
}

async function connect(event: WebSocketEvent): Promise<APIGatewayProxyResultV2> {
  const context = event.requestContext.authorizer ?? {};
  const connectionId = event.requestContext.connectionId;
  const sessionId = String(context.sessionId ?? "");
  const role = String(context.role ?? "");
  const clientId = String(context.clientId ?? "");
  const generation = Number(context.generation);
  const ticketOwnerSub = String(context.ownerSub ?? "");
  if (!connectionId || !sessionId || !clientId || !["mac", "controller"].includes(role)) {
    return { statusCode: 401 };
  }
  const session = await dynamo.send(
    new GetCommand({ TableName: tableName, Key: { PK: `SESSION#${sessionId}`, SK: "META" }, ConsistentRead: true }),
  );
  if (
    !session.Item ||
    session.Item.status !== "active" ||
    Number(session.Item.ttl) <= nowSeconds() ||
    Number(session.Item.generation) !== generation
  ) {
    return { statusCode: 410 };
  }
  const principal = await dynamo.send(
    new GetCommand({
      TableName: tableName,
      Key: {
        PK: `${role === "mac" ? "DEVICE" : "CONTROLLER"}#${clientId}`,
        SK: "META",
      },
      ConsistentRead: true,
    }),
  );
  if (
    !principal.Item ||
    principal.Item.revokedAt ||
    (principal.Item.ttl !== undefined && Number(principal.Item.ttl) <= nowSeconds()) ||
    (role === "mac" && principal.Item.deviceId !== clientId) ||
    (role === "controller" && principal.Item.sessionId !== sessionId)
  ) {
    return { statusCode: 403 };
  }
  if (role === "controller" && principal.Item.accessMode === "account") {
    if (!accountTenantMatches({
      controllerOwnerSub: principal.Item.ownerSub,
      sessionOwnerSub: session.Item.ownerSub,
      assertedOwnerSub: ticketOwnerSub,
    })) {
      return { statusCode: 403 };
    }
  } else if (ticketOwnerSub) {
    return { statusCode: 403 };
  }
  if (
    role === "mac" &&
    typeof session.Item.ownerSub === "string" &&
    principal.Item.ownerSub !== session.Item.ownerSub
  ) {
    return { statusCode: 403 };
  }
  const sessionOwnerSub = typeof session.Item.ownerSub === "string"
    ? session.Item.ownerSub
    : undefined;
  const connectionOwnerSub = role === "mac" ? sessionOwnerSub : ticketOwnerSub || undefined;
  const connectedAt = nowSeconds();
  const ttl = nowSeconds() + 3 * 60 * 60;
  await dynamo.send(
    new TransactWriteCommand({
      TransactItems: [
        {
          Put: {
            TableName: tableName,
            Item: {
              PK: `CONNECTION#${connectionId}`,
              SK: "META",
              connectionId,
              sessionId,
              role,
              clientId,
              generation,
              ...(connectionOwnerSub ? { ownerSub: connectionOwnerSub } : {}),
              connectedAt,
              ttl,
            },
          },
        },
        {
          Put: {
            TableName: tableName,
            Item: {
              PK: `SESSION#${sessionId}`,
              SK: `SOCKET#${role}#${clientId}`,
              connectionId,
              role,
              clientId,
              generation,
              ...(connectionOwnerSub ? { ownerSub: connectionOwnerSub } : {}),
              connectedAt,
              ttl,
            },
          },
        },
        ...(role === "mac" && sessionOwnerSub
          ? [{
              Update: {
                TableName: tableName,
                Key: { PK: `USER#${sessionOwnerSub}`, SK: `DEVICE#${clientId}` },
                UpdateExpression:
                  "SET #status = :online, lastSeenAt = :now, activeSessionId = :session, activeConnectionId = :connection",
                ConditionExpression: "attribute_exists(PK)",
                ExpressionAttributeNames: { "#status": "status" },
                ExpressionAttributeValues: {
                  ":online": "online",
                  ":now": connectedAt,
                  ":session": sessionId,
                  ":connection": connectionId,
                },
              },
            }]
          : []),
      ],
    }),
  );
  return { statusCode: 200 };
}

async function disconnect(event: WebSocketEvent): Promise<APIGatewayProxyResultV2> {
  const connectionId = event.requestContext.connectionId;
  const source = await dynamo.send(
    new GetCommand({ TableName: tableName, Key: { PK: `CONNECTION#${connectionId}`, SK: "META" } }),
  );
  await dynamo.send(
    new DeleteCommand({ TableName: tableName, Key: { PK: `CONNECTION#${connectionId}`, SK: "META" } }),
  );
  if (source.Item) {
    try {
      const socket = await dynamo.send(
        new DeleteCommand({
          TableName: tableName,
          Key: {
            PK: `SESSION#${String(source.Item.sessionId)}`,
            SK: `SOCKET#${String(source.Item.role)}#${String(source.Item.clientId)}`,
          },
          ConditionExpression: "connectionId = :connectionId",
          ExpressionAttributeValues: { ":connectionId": connectionId },
          ReturnValues: "ALL_OLD",
        }),
      );
      if (
        socket.Attributes &&
        source.Item.role === "mac" &&
        typeof source.Item.ownerSub === "string"
      ) {
        try {
          await dynamo.send(
            new UpdateCommand({
              TableName: tableName,
              Key: {
                PK: `USER#${source.Item.ownerSub}`,
                SK: `DEVICE#${String(source.Item.clientId)}`,
              },
              UpdateExpression:
                "SET #status = :offline, lastSeenAt = :now REMOVE activeSessionId, activeConnectionId, sessionStartedAt",
              ConditionExpression: "activeConnectionId = :connection",
              ExpressionAttributeNames: { "#status": "status" },
              ExpressionAttributeValues: {
                ":offline": "offline",
                ":now": nowSeconds(),
                ":connection": connectionId,
              },
            }),
          );
        } catch {
          // A replacement Mac connection is already online.
        }
      }
    } catch {
      // A newer make-before-break socket already owns the current mapping.
    }
  }
  // WebSocket proxy integrations still expect a complete proxy response even
  // though the peer has already closed by the time $disconnect is delivered.
  return { statusCode: 200, body: "" };
}

export async function handler(
  event: WebSocketEvent,
): Promise<APIGatewayAuthorizerResult | APIGatewayProxyResultV2> {
  if (event.type === "REQUEST") return authorize(event);
  if (event.requestContext.eventType === "CONNECT" || event.requestContext.routeKey === "$connect") {
    return connect(event);
  }
  if (event.requestContext.eventType === "DISCONNECT" || event.requestContext.routeKey === "$disconnect") {
    return disconnect(event);
  }
  return { statusCode: 400 };
}
