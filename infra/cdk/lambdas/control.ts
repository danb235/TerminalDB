import {
  ApiGatewayManagementApiClient,
  DeleteConnectionCommand,
} from "@aws-sdk/client-apigatewaymanagementapi";
import {
  DeleteCommand,
  GetCommand,
  PutCommand,
  QueryCommand,
  TransactWriteCommand,
  type TransactWriteCommandInput,
  UpdateCommand,
} from "@aws-sdk/lib-dynamodb";
import type {
  APIGatewayProxyEventV2,
  APIGatewayProxyHandlerV2,
  APIGatewayProxyStructuredResultV2,
} from "aws-lambda";

import {
  constantEqual,
  dynamo,
  json,
  jsonWebKeyField,
  nowSeconds,
  parseBody,
  randomSecret,
  saltedHash,
  sha256,
  stringField,
  tableName,
  verifyAuthenticatedRequest,
} from "./common.js";

interface AdminEnrollmentEvent {
  readonly action: "createEnrollment";
}

const pairingDisabled = process.env.DISABLE_NEW_PAIRINGS === "true";
const ACTIVE_SESSION_TTL_SECONDS = 24 * 60 * 60;
const ENDED_RECORD_TTL_SECONDS = 7 * 24 * 60 * 60;
const publicRegion = process.env.AWS_REGION ?? "us-west-2";
const stage = process.env.STAGE ?? "dev";
const publicWebSocketUrl = process.env.PUBLIC_WEBSOCKET_URL ?? "";
const websocketManagementEndpoint = process.env.WEBSOCKET_MANAGEMENT_ENDPOINT ?? "";
const websocketManagement = websocketManagementEndpoint
  ? new ApiGatewayManagementApiClient({ endpoint: websocketManagementEndpoint })
  : undefined;

async function disconnectConnections(connectionIds: readonly string[]): Promise<void> {
  if (!websocketManagement || connectionIds.length === 0) return;
  await Promise.allSettled(
    connectionIds.map((connectionId) =>
      websocketManagement.send(new DeleteConnectionCommand({ ConnectionId: connectionId })),
    ),
  );
}

async function createEnrollment(): Promise<Record<string, unknown>> {
  const code = randomSecret(24);
  const salt = randomSecret(16);
  const id = crypto.randomUUID();
  const expiresAt = nowSeconds() + 15 * 60;
  await dynamo.send(
    new PutCommand({
      TableName: tableName,
      Item: {
        PK: "ENROLLMENTS",
        SK: `CODE#${id}`,
        salt,
        secretHash: saltedHash(salt, code),
        createdAt: nowSeconds(),
        expiresAt,
        ttl: expiresAt,
      },
    }),
  );
  return { enrollmentCode: code, expiresAt };
}

async function redeemEnrollment(
  event: APIGatewayProxyEventV2,
): Promise<APIGatewayProxyStructuredResultV2> {
  const body = parseBody(event);
  const code = stringField(body, "code", 128);
  const records = await dynamo.send(
    new QueryCommand({
      TableName: tableName,
      KeyConditionExpression: "PK = :pk AND begins_with(SK, :prefix)",
      ExpressionAttributeValues: { ":pk": "ENROLLMENTS", ":prefix": "CODE#" },
      Limit: 20,
      ConsistentRead: true,
    }),
  );
  const match = records.Items?.find(
    (item) =>
      Number(item.expiresAt) > nowSeconds() &&
      constantEqual(String(item.secretHash), saltedHash(String(item.salt), code)),
  );
  if (!match) return json(401, { error: "Enrollment code is invalid or expired" });

  const deviceId = crypto.randomUUID();
  const registeredAt = nowSeconds();
  const temporary = body.temporary === true;
  await dynamo.send(
    new TransactWriteCommand({
      TransactItems: [
        {
          Delete: {
            TableName: tableName,
            Key: { PK: match.PK, SK: match.SK },
            ConditionExpression: "attribute_exists(PK)",
          },
        },
        {
          Put: {
            TableName: tableName,
            Item: {
              PK: `DEVICE#${deviceId}`,
              SK: "META",
              deviceId,
              name: stringField(body, "deviceName", 100),
              signingPublicKey: jsonWebKeyField(body, "signingPublicKey"),
              agreementPublicKey: jsonWebKeyField(body, "agreementPublicKey"),
              registeredAt,
              ...(temporary
                ? {
                    temporary: true,
                    ttl: registeredAt + ENDED_RECORD_TTL_SECONDS,
                  }
                : {}),
            },
            ConditionExpression: "attribute_not_exists(PK)",
          },
        },
      ],
    }),
  );
  return json(201, { deviceId, protocolVersion: 1 });
}

async function createSession(
  event: APIGatewayProxyEventV2,
): Promise<APIGatewayProxyStructuredResultV2> {
  const { principalId, principal } = await verifyAuthenticatedRequest(event);
  if (principal.deviceId !== principalId) return json(403, { error: "Only a registered Mac can start a session" });
  const body = parseBody(event);
  if (Number(body.protocolVersion) !== 1) {
    return json(409, { error: "Protocol version incompatible" });
  }
  const sessionId = randomSecret(18);
  const generation = 1;
  const createdAt = nowSeconds();
  const ttl = createdAt + ACTIVE_SESSION_TTL_SECONDS;
  await dynamo.send(
    new TransactWriteCommand({
      TransactItems: [
        {
          Put: {
            TableName: tableName,
            Item: {
              PK: `SESSION#${sessionId}`,
              SK: "META",
              sessionId,
              deviceId: principalId,
              generation,
              protocolVersion: 1,
              status: "active",
              controllerCount: 0,
              createdAt,
              ttl,
              agreementPublicKey: principal.agreementPublicKey,
            },
            ConditionExpression: "attribute_not_exists(PK)",
          },
        },
        {
          Put: {
            TableName: tableName,
            Item: {
              PK: `DEVICE#${principalId}`,
              SK: `SESSION#${sessionId}`,
              sessionId,
              status: "active",
              createdAt,
              ttl,
            },
          },
        },
      ],
    }),
  );
  return json(201, { sessionId, generation });
}

async function createPairing(
  event: APIGatewayProxyEventV2,
): Promise<APIGatewayProxyStructuredResultV2> {
  if (pairingDisabled) return json(503, { error: "New pairings are temporarily disabled" });
  const { principalId, principal } = await verifyAuthenticatedRequest(event);
  if (principal.deviceId !== principalId) return json(403, { error: "Only a registered Mac can create pairings" });
  const body = parseBody(event);
  const sessionId = stringField(body, "sessionId", 128);
  const session = await dynamo.send(
    new GetCommand({ TableName: tableName, Key: { PK: `SESSION#${sessionId}`, SK: "META" }, ConsistentRead: true }),
  );
  if (!session.Item || session.Item.deviceId !== principalId || session.Item.status !== "active") {
    return json(404, { error: "Active session not found" });
  }
  const existing = await dynamo.send(
    new QueryCommand({
      TableName: tableName,
      KeyConditionExpression: "PK = :pk AND begins_with(SK, :prefix)",
      FilterExpression: "expiresAt > :now",
      ExpressionAttributeValues: {
        ":pk": `SESSION#${sessionId}`,
        ":prefix": "PAIRING#",
        ":now": nowSeconds(),
      },
      Select: "COUNT",
    }),
  );
  if ((existing.Count ?? 0) >= 3) return json(429, { error: "This Mac already has three active pairing codes" });

  const pairingId = randomSecret(18);
  const secret = randomSecret(32);
  const salt = randomSecret(16);
  const expiresAt = nowSeconds() + 10 * 60;
  const item = {
    sessionId,
    deviceId: principalId,
    pairingId,
    salt,
    secretHash: saltedHash(salt, secret),
    createdAt: nowSeconds(),
    expiresAt,
    ttl: expiresAt,
    macAgreementPublicKey: session.Item.agreementPublicKey,
  };
  await dynamo.send(
    new TransactWriteCommand({
      TransactItems: [
        {
          Put: {
            TableName: tableName,
            Item: { PK: `PAIRING#${pairingId}`, SK: "META", ...item },
            ConditionExpression: "attribute_not_exists(PK)",
          },
        },
        {
          Put: {
            TableName: tableName,
            Item: { PK: `SESSION#${sessionId}`, SK: `PAIRING#${pairingId}`, ...item },
          },
        },
      ],
    }),
  );
  return json(201, {
    pairingId,
    pairingPath: `/pair/${pairingId}#${secret}`,
    expiresAt,
  });
}

async function redeemPairing(
  event: APIGatewayProxyEventV2,
  pairingId: string,
): Promise<APIGatewayProxyStructuredResultV2> {
  const body = parseBody(event);
  const pairing = await dynamo.send(
    new GetCommand({ TableName: tableName, Key: { PK: `PAIRING#${pairingId}`, SK: "META" }, ConsistentRead: true }),
  );
  if (!pairing.Item || Number(pairing.Item.expiresAt) <= nowSeconds()) {
    return json(410, { error: "Pairing link expired" });
  }
  const expected = saltedHash(String(pairing.Item.salt), stringField(body, "secret", 128));
  if (!constantEqual(String(pairing.Item.secretHash), expected)) return json(401, { error: "Invalid pairing secret" });
  const sessionId = String(pairing.Item.sessionId);
  const session = await dynamo.send(
    new GetCommand({ TableName: tableName, Key: { PK: `SESSION#${sessionId}`, SK: "META" }, ConsistentRead: true }),
  );
  if (!session.Item || session.Item.status !== "active") return json(410, { error: "Remote session ended" });
  if (
    Number(body.protocolVersion) !== 1 ||
    Number(session.Item.protocolVersion ?? 1) !== 1
  ) {
    return json(409, { error: "Protocol version incompatible" });
  }
  const controllers = await dynamo.send(
    new QueryCommand({
      TableName: tableName,
      KeyConditionExpression: "PK = :pk AND begins_with(SK, :prefix)",
      ExpressionAttributeValues: { ":pk": `SESSION#${sessionId}`, ":prefix": "CONTROLLER#" },
      Select: "COUNT",
    }),
  );
  if ((controllers.Count ?? 0) >= 5) return json(429, { error: "This Mac already has five trusted controllers" });

  const controllerId = crypto.randomUUID();
  const createdAt = nowSeconds();
  const controller = {
    controllerId,
    pairingId,
    sessionId,
    deviceId: pairing.Item.deviceId,
    name: stringField(body, "deviceName", 100),
    signingPublicKey: jsonWebKeyField(body, "signingPublicKey"),
    agreementPublicKey: jsonWebKeyField(body, "agreementPublicKey"),
    createdAt,
    ttl: createdAt + ACTIVE_SESSION_TTL_SECONDS,
  };
  await dynamo.send(
    new TransactWriteCommand({
      TransactItems: [
        {
          Delete: {
            TableName: tableName,
            Key: { PK: `PAIRING#${pairingId}`, SK: "META" },
            ConditionExpression: "secretHash = :expected",
            ExpressionAttributeValues: { ":expected": expected },
          },
        },
        {
          Delete: {
            TableName: tableName,
            Key: { PK: `SESSION#${sessionId}`, SK: `PAIRING#${pairingId}` },
          },
        },
        {
          Put: {
            TableName: tableName,
            Item: { PK: `CONTROLLER#${controllerId}`, SK: "META", ...controller },
            ConditionExpression: "attribute_not_exists(PK)",
          },
        },
        {
          Put: {
            TableName: tableName,
            Item: { PK: `SESSION#${sessionId}`, SK: `CONTROLLER#${controllerId}`, ...controller },
          },
        },
        {
          Update: {
            TableName: tableName,
            Key: { PK: `SESSION#${sessionId}`, SK: "META" },
            UpdateExpression: "ADD controllerCount :one",
            ConditionExpression:
              "#status = :active AND (attribute_not_exists(controllerCount) OR controllerCount < :maximum)",
            ExpressionAttributeNames: { "#status": "status" },
            ExpressionAttributeValues: {
              ":one": 1,
              ":maximum": 5,
              ":active": "active",
            },
          },
        },
      ],
    }),
  );
  return json(201, {
    controllerId,
    sessionId,
    generation: Number(session.Item.generation),
    protocolVersion: 1,
    macAgreementPublicKey: pairing.Item.macAgreementPublicKey,
  });
}

async function createTicket(
  event: APIGatewayProxyEventV2,
): Promise<APIGatewayProxyStructuredResultV2> {
  const { principalId, principal } = await verifyAuthenticatedRequest(event);
  const body = parseBody(event);
  const sessionId = stringField(body, "sessionId", 128);
  const requestedRole = stringField(body, "role", 20);
  const role = principal.deviceId === principalId ? "mac" : "controller";
  if (requestedRole !== role) return json(403, { error: "Role does not match principal" });
  if (role === "controller" && principal.sessionId !== sessionId) return json(403, { error: "Cross-session ticket rejected" });
  const session = await dynamo.send(
    new GetCommand({ TableName: tableName, Key: { PK: `SESSION#${sessionId}`, SK: "META" }, ConsistentRead: true }),
  );
  if (!session.Item || session.Item.status !== "active") return json(410, { error: "Remote session ended" });
  if (role === "mac" && session.Item.deviceId !== principalId) return json(403, { error: "Cross-session ticket rejected" });

  const ticket = randomSecret(32);
  const expiresAt = nowSeconds() + 60;
  const sessionTtl = nowSeconds() + ACTIVE_SESSION_TTL_SECONDS;
  const refreshes: NonNullable<TransactWriteCommandInput["TransactItems"]> = [
    {
      Update: {
        TableName: tableName,
        Key: { PK: `SESSION#${sessionId}`, SK: "META" },
        UpdateExpression: "SET #ttl = :ttl",
        ConditionExpression: "#status = :active",
        ExpressionAttributeNames: { "#status": "status", "#ttl": "ttl" },
        ExpressionAttributeValues: { ":ttl": sessionTtl, ":active": "active" },
      },
    },
    {
      Update: {
        TableName: tableName,
        Key: { PK: `DEVICE#${String(session.Item.deviceId)}`, SK: `SESSION#${sessionId}` },
        UpdateExpression: "SET #ttl = :ttl",
        ExpressionAttributeNames: { "#ttl": "ttl" },
        ExpressionAttributeValues: { ":ttl": sessionTtl },
      },
    },
    ...(role === "controller"
      ? [
          {
            Update: {
              TableName: tableName,
              Key: { PK: `CONTROLLER#${principalId}`, SK: "META" },
              UpdateExpression: "SET #ttl = :ttl",
              ConditionExpression: "attribute_not_exists(revokedAt)",
              ExpressionAttributeNames: { "#ttl": "ttl" },
              ExpressionAttributeValues: { ":ttl": sessionTtl },
            },
          },
          {
            Update: {
              TableName: tableName,
              Key: { PK: `SESSION#${sessionId}`, SK: `CONTROLLER#${principalId}` },
              UpdateExpression: "SET #ttl = :ttl",
              ExpressionAttributeNames: { "#ttl": "ttl" },
              ExpressionAttributeValues: { ":ttl": sessionTtl },
            },
          },
        ]
      : []),
  ];
  await dynamo.send(
    new TransactWriteCommand({
      TransactItems: [
        {
          Put: {
            TableName: tableName,
            Item: {
              PK: `TICKET#${sha256(ticket)}`,
              SK: "META",
              sessionId,
              role,
              clientId: principalId,
              generation: session.Item.generation,
              expiresAt,
              ttl: expiresAt,
            },
            ConditionExpression: "attribute_not_exists(PK)",
          },
        },
        ...refreshes,
      ],
    }),
  );
  if (!publicWebSocketUrl) throw new Error("Public WebSocket URL is not configured");
  return json(201, { ticket, expiresAt, websocketUrl: publicWebSocketUrl });
}

async function revokeController(
  event: APIGatewayProxyEventV2,
  controllerId: string,
): Promise<APIGatewayProxyStructuredResultV2> {
  const { principalId, principal } = await verifyAuthenticatedRequest(event);
  const controller = await dynamo.send(
    new GetCommand({ TableName: tableName, Key: { PK: `CONTROLLER#${controllerId}`, SK: "META" } }),
  );
  if (!controller.Item) return json(404, { error: "Controller not found" });
  const macOwnsController =
    principal.deviceId === principalId &&
    controller.Item.deviceId === principalId;
  const controllerRevokesSelf =
    principalId === controllerId &&
    principal.sessionId === controller.Item.sessionId &&
    principal.deviceId === controller.Item.deviceId;
  if (!macOwnsController && !controllerRevokesSelf) {
    return json(403, { error: "A controller can revoke only itself" });
  }
  if (controller.Item.revokedAt) return json(200, { revoked: true });
  const socket = await dynamo.send(
    new GetCommand({
      TableName: tableName,
      Key: {
        PK: `SESSION#${String(controller.Item.sessionId)}`,
        SK: `SOCKET#controller#${controllerId}`,
      },
      ConsistentRead: true,
    }),
  );
  const revokedAt = nowSeconds();
  await dynamo.send(
    new TransactWriteCommand({
      TransactItems: [
        {
          Update: {
            TableName: tableName,
            Key: { PK: `CONTROLLER#${controllerId}`, SK: "META" },
            UpdateExpression: "SET revokedAt = :now, #ttl = :ttl",
            ExpressionAttributeNames: { "#ttl": "ttl" },
            ExpressionAttributeValues: {
              ":now": revokedAt,
              ":ttl": revokedAt + ENDED_RECORD_TTL_SECONDS,
            },
          },
        },
        {
          Delete: {
            TableName: tableName,
            Key: { PK: `SESSION#${String(controller.Item.sessionId)}`, SK: `CONTROLLER#${controllerId}` },
          },
        },
        {
          Delete: {
            TableName: tableName,
            Key: {
              PK: `SESSION#${String(controller.Item.sessionId)}`,
              SK: `SOCKET#controller#${controllerId}`,
            },
          },
        },
        {
          Update: {
            TableName: tableName,
            Key: { PK: `SESSION#${String(controller.Item.sessionId)}`, SK: "META" },
            UpdateExpression: "ADD controllerCount :minusOne",
            ConditionExpression: "controllerCount >= :one",
            ExpressionAttributeValues: { ":minusOne": -1, ":one": 1 },
          },
        },
        ...(socket.Item?.connectionId
          ? [{
              Delete: {
                TableName: tableName,
                Key: {
                  PK: `CONNECTION#${String(socket.Item.connectionId)}`,
                  SK: "META",
                },
              },
            }]
          : []),
      ],
    }),
  );
  if (socket.Item?.connectionId) {
    await disconnectConnections([String(socket.Item.connectionId)]);
  }
  return json(200, { revoked: true });
}

async function endSession(
  event: APIGatewayProxyEventV2,
  sessionId: string,
): Promise<APIGatewayProxyStructuredResultV2> {
  const { principalId, principal } = await verifyAuthenticatedRequest(event);
  if (principal.deviceId !== principalId) return json(403, { error: "Only the Mac can end a session" });
  const endedAt = nowSeconds();
  await dynamo.send(
    new UpdateCommand({
      TableName: tableName,
      Key: { PK: `SESSION#${sessionId}`, SK: "META" },
      UpdateExpression: "SET #status = :ended, endedAt = :now, #ttl = :ttl ADD generation :one",
      ConditionExpression: "deviceId = :device AND #status = :active",
      ExpressionAttributeNames: { "#status": "status", "#ttl": "ttl" },
      ExpressionAttributeValues: {
        ":ended": "ended",
        ":now": endedAt,
        ":ttl": endedAt + ENDED_RECORD_TTL_SECONDS,
        ":one": 1,
        ":device": principalId,
        ":active": "active",
      },
    }),
  );
  const [controllers, sockets] = await Promise.all([
    dynamo.send(
      new QueryCommand({
        TableName: tableName,
        KeyConditionExpression: "PK = :pk AND begins_with(SK, :prefix)",
        ExpressionAttributeValues: {
          ":pk": `SESSION#${sessionId}`,
          ":prefix": "CONTROLLER#",
        },
        ConsistentRead: true,
        Limit: 5,
      }),
    ),
    dynamo.send(
      new QueryCommand({
        TableName: tableName,
        KeyConditionExpression: "PK = :pk AND begins_with(SK, :prefix)",
        ExpressionAttributeValues: {
          ":pk": `SESSION#${sessionId}`,
          ":prefix": "SOCKET#controller#",
        },
        ConsistentRead: true,
        Limit: 5,
      }),
    ),
  ]);
  const socketsByController = new Map(
    (sockets.Items ?? []).map((socket) => [String(socket.clientId), socket]),
  );
  if (controllers.Items && controllers.Items.length > 0) {
    await dynamo.send(
      new TransactWriteCommand({
        TransactItems: controllers.Items.flatMap((controller) => {
          const controllerId = String(controller.controllerId);
          const connectionId = socketsByController.get(controllerId)?.connectionId;
          return [
            {
              Update: {
                TableName: tableName,
                Key: { PK: `CONTROLLER#${controllerId}`, SK: "META" },
                UpdateExpression: "SET revokedAt = :now, #ttl = :ttl",
                ExpressionAttributeNames: { "#ttl": "ttl" },
                ExpressionAttributeValues: {
                  ":now": endedAt,
                  ":ttl": endedAt + ENDED_RECORD_TTL_SECONDS,
                },
              },
            },
            {
              Delete: {
                TableName: tableName,
                Key: { PK: `SESSION#${sessionId}`, SK: `CONTROLLER#${controllerId}` },
              },
            },
            {
              Delete: {
                TableName: tableName,
                Key: { PK: `SESSION#${sessionId}`, SK: `SOCKET#controller#${controllerId}` },
              },
            },
            ...(connectionId
              ? [{
                  Delete: {
                    TableName: tableName,
                    Key: { PK: `CONNECTION#${String(connectionId)}`, SK: "META" },
                  },
                }]
              : []),
          ];
        }),
      }),
    );
  }
  await dynamo.send(
    new UpdateCommand({
      TableName: tableName,
      Key: { PK: `DEVICE#${principalId}`, SK: `SESSION#${sessionId}` },
      UpdateExpression: "SET #status = :ended, endedAt = :now, #ttl = :ttl",
      ExpressionAttributeNames: { "#status": "status", "#ttl": "ttl" },
      ExpressionAttributeValues: {
        ":ended": "ended",
        ":now": endedAt,
        ":ttl": endedAt + ENDED_RECORD_TTL_SECONDS,
      },
    }),
  );
  await disconnectConnections(
    [...socketsByController.values()].flatMap((socket) =>
      socket.connectionId ? [String(socket.connectionId)] : [],
    ),
  );
  return json(200, { ended: true });
}

async function getControllerKey(
  event: APIGatewayProxyEventV2,
  sessionId: string,
  controllerId: string,
): Promise<APIGatewayProxyStructuredResultV2> {
  const { principalId, principal } = await verifyAuthenticatedRequest(event);
  if (principal.deviceId !== principalId) return json(403, { error: "Only the Mac can read controller keys" });
  const session = await dynamo.send(
    new GetCommand({ TableName: tableName, Key: { PK: `SESSION#${sessionId}`, SK: "META" }, ConsistentRead: true }),
  );
  if (!session.Item || session.Item.deviceId !== principalId || session.Item.status !== "active") {
    return json(404, { error: "Active session not found" });
  }
  const controller = await dynamo.send(
    new GetCommand({ TableName: tableName, Key: { PK: `CONTROLLER#${controllerId}`, SK: "META" }, ConsistentRead: true }),
  );
  if (
    !controller.Item ||
    controller.Item.sessionId !== sessionId ||
    controller.Item.revokedAt
  ) {
    return json(404, { error: "Trusted controller not found" });
  }
  return json(200, {
    controllerId,
    pairingId: controller.Item.pairingId,
    agreementPublicKey: controller.Item.agreementPublicKey,
    generation: session.Item.generation,
  });
}

async function listControllers(
  event: APIGatewayProxyEventV2,
  sessionId: string,
): Promise<APIGatewayProxyStructuredResultV2> {
  const { principalId, principal } = await verifyAuthenticatedRequest(event);
  if (principal.deviceId !== principalId) {
    return json(403, { error: "Only the Mac can list trusted controllers" });
  }
  const session = await dynamo.send(
    new GetCommand({
      TableName: tableName,
      Key: { PK: `SESSION#${sessionId}`, SK: "META" },
      ConsistentRead: true,
    }),
  );
  if (
    !session.Item ||
    session.Item.deviceId !== principalId ||
    session.Item.status !== "active"
  ) {
    return json(404, { error: "Active session not found" });
  }
  const [controllers, sockets] = await Promise.all([
    dynamo.send(
      new QueryCommand({
        TableName: tableName,
        KeyConditionExpression: "PK = :pk AND begins_with(SK, :prefix)",
        ExpressionAttributeValues: {
          ":pk": `SESSION#${sessionId}`,
          ":prefix": "CONTROLLER#",
        },
        ConsistentRead: true,
      }),
    ),
    dynamo.send(
      new QueryCommand({
        TableName: tableName,
        KeyConditionExpression: "PK = :pk AND begins_with(SK, :prefix)",
        ExpressionAttributeValues: {
          ":pk": `SESSION#${sessionId}`,
          ":prefix": "SOCKET#controller#",
        },
        ConsistentRead: true,
      }),
    ),
  ]);
  const connected = new Set(
    (sockets.Items ?? []).map((item) => String(item.clientId)),
  );
  return json(200, {
    controllers: (controllers.Items ?? [])
      .map((controller) => ({
        controllerId: String(controller.controllerId),
        name: String(controller.name ?? "Web browser"),
        createdAt: Number(controller.createdAt),
        connected: connected.has(String(controller.controllerId)),
      }))
      .sort((left, right) => right.createdAt - left.createdAt),
  });
}

async function handleHttp(
  event: APIGatewayProxyEventV2,
): Promise<APIGatewayProxyStructuredResultV2> {
  const method = event.requestContext.http.method;
  const path = event.rawPath;
  if (method === "GET" && path === "/api/config") {
    return json(200, {
      apiBaseUrl: "",
      websocketUrl: "/socket",
      protocolVersion: 1,
      region: publicRegion,
      stage,
      pairingEnabled: !pairingDisabled,
      mockMode: false,
    });
  }
  if (method === "GET") {
    const controllerListMatch = path.match(
      /^\/api\/v1\/sessions\/([^/]+)\/controllers$/u,
    );
    if (controllerListMatch?.[1]) {
      return listControllers(
        event,
        decodeURIComponent(controllerListMatch[1]),
      );
    }
    const controllerKeyMatch = path.match(
      /^\/api\/v1\/sessions\/([^/]+)\/controllers\/([^/]+)$/u,
    );
    if (controllerKeyMatch?.[1] && controllerKeyMatch[2]) {
      return getControllerKey(
        event,
        decodeURIComponent(controllerKeyMatch[1]),
        decodeURIComponent(controllerKeyMatch[2]),
      );
    }
  }
  if (method !== "POST") return json(405, { error: "Method not allowed" });
  if (path === "/api/v1/enrollments/redeem") return redeemEnrollment(event);
  if (path === "/api/v1/sessions") return createSession(event);
  if (path === "/api/v1/pairings") return createPairing(event);
  if (path === "/api/v1/tickets") return createTicket(event);
  const pairingMatch = path.match(/^\/api\/v1\/pairings\/([^/]+)\/redeem$/u);
  if (pairingMatch?.[1]) return redeemPairing(event, decodeURIComponent(pairingMatch[1]));
  const revokeMatch = path.match(/^\/api\/v1\/controllers\/([^/]+)\/revoke$/u);
  if (revokeMatch?.[1]) return revokeController(event, decodeURIComponent(revokeMatch[1]));
  const endMatch = path.match(/^\/api\/v1\/sessions\/([^/]+)\/end$/u);
  if (endMatch?.[1]) return endSession(event, decodeURIComponent(endMatch[1]));
  return json(404, { error: "Not found" });
}

export const handler: APIGatewayProxyHandlerV2 = async (
  event: APIGatewayProxyEventV2 | AdminEnrollmentEvent,
) => {
  try {
    if ((event as AdminEnrollmentEvent).action === "createEnrollment") {
      return await createEnrollment();
    }
    return await handleHttp(event as APIGatewayProxyEventV2);
  } catch (error) {
    const statusCode =
      error instanceof SyntaxError || error instanceof TypeError
        ? 400
        : error instanceof Error && /auth|signature|principal|replay|stale/iu.test(error.message)
          ? 401
          : 409;
    return json(statusCode, { error: error instanceof Error ? error.message : "Request failed" });
  }
};
