import {
  ApiGatewayManagementApiClient,
  DeleteConnectionCommand,
} from "@aws-sdk/client-apigatewaymanagementapi";
import {
  DeleteCommand,
  GetCommand,
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
  accountTenantMatches,
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
const cognitoAuthEnabled = process.env.COGNITO_AUTH_ENABLED === "true";
const cognitoClientId = process.env.COGNITO_CLIENT_ID ?? "";
const cognitoDomain = process.env.COGNITO_DOMAIN ?? "";
const cognitoIssuer = process.env.COGNITO_ISSUER ?? "";
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

function accountSubject(event: APIGatewayProxyEventV2): string {
  const context = event.requestContext as typeof event.requestContext & {
    authorizer?: { jwt?: { claims?: Record<string, string | number | boolean | string[]> } };
  };
  const authorizer = context.authorizer;
  const sub = authorizer?.jwt?.claims?.sub;
  const tokenUse = authorizer?.jwt?.claims?.token_use;
  if (
    tokenUse !== "access" ||
    typeof sub !== "string" ||
    !/^[\w-]{8,128}$/u.test(sub)
  ) {
    throw new Error("Account authentication required");
  }
  return sub;
}

async function createEnrollment(ownerSub?: string): Promise<Record<string, unknown>> {
  const code = randomSecret(24);
  const salt = randomSecret(16);
  const id = crypto.randomUUID();
  const expiresAt = nowSeconds() + 15 * 60;
  if (ownerSub) {
    const active = await dynamo.send(
      new QueryCommand({
        TableName: tableName,
        KeyConditionExpression: "PK = :pk AND begins_with(SK, :prefix)",
        FilterExpression: "expiresAt > :now",
        ExpressionAttributeValues: {
          ":pk": `USER#${ownerSub}`,
          ":prefix": "ENROLLMENT#",
          ":now": nowSeconds(),
        },
        Select: "COUNT",
        ConsistentRead: true,
      }),
    );
    if ((active.Count ?? 0) >= 5) throw new Error("Five active Mac enrollment codes already exist");
  }
  const item = {
    enrollmentId: id,
    salt,
    secretHash: saltedHash(salt, code),
    createdAt: nowSeconds(),
    expiresAt,
    ttl: expiresAt,
    ...(ownerSub ? { ownerSub } : {}),
  };
  await dynamo.send(
    new TransactWriteCommand({
      TransactItems: [
        {
          Put: {
            TableName: tableName,
            Item: { PK: `ENROLLMENT#${sha256(code)}`, SK: "META", ...item },
            ConditionExpression: "attribute_not_exists(PK)",
          },
        },
        ...(ownerSub
          ? [{
              Put: {
                TableName: tableName,
                Item: { PK: `USER#${ownerSub}`, SK: `ENROLLMENT#${id}`, ...item },
              },
            }]
          : []),
      ],
    }),
  );
  return { enrollmentCode: code, expiresAt };
}

async function redeemEnrollment(
  event: APIGatewayProxyEventV2,
): Promise<APIGatewayProxyStructuredResultV2> {
  const body = parseBody(event);
  const code = stringField(body, "code", 128);
  const direct = await dynamo.send(
    new GetCommand({
      TableName: tableName,
      Key: { PK: `ENROLLMENT#${sha256(code)}`, SK: "META" },
      ConsistentRead: true,
    }),
  );
  let match = direct.Item;
  // Read the legacy single-tenant enrollment partition during rolling upgrades.
  if (!match) {
    const records = await dynamo.send(
      new QueryCommand({
        TableName: tableName,
        KeyConditionExpression: "PK = :pk AND begins_with(SK, :prefix)",
        ExpressionAttributeValues: { ":pk": "ENROLLMENTS", ":prefix": "CODE#" },
        Limit: 20,
        ConsistentRead: true,
      }),
    );
    match = records.Items?.find(
      (item) =>
        Number(item.expiresAt) > nowSeconds() &&
        constantEqual(String(item.secretHash), saltedHash(String(item.salt), code)),
    );
  }
  if (
    match &&
    (Number(match.expiresAt) <= nowSeconds() ||
      !constantEqual(String(match.secretHash), saltedHash(String(match.salt), code)))
  ) {
    match = undefined;
  }
  if (!match) return json(401, { error: "Enrollment code is invalid or expired" });

  const deviceId = crypto.randomUUID();
  const registeredAt = nowSeconds();
  const temporary = body.temporary === true;
  const ownerSub = typeof match.ownerSub === "string" ? match.ownerSub : undefined;
  const deviceName = stringField(body, "deviceName", 100);
  const transactItems: NonNullable<TransactWriteCommandInput["TransactItems"]> = [
    {
      Delete: {
        TableName: tableName,
        Key: { PK: match.PK, SK: match.SK },
        ConditionExpression: "attribute_exists(PK)",
      },
    },
    ...(ownerSub && match.enrollmentId
      ? [{
          Delete: {
            TableName: tableName,
            Key: { PK: `USER#${ownerSub}`, SK: `ENROLLMENT#${String(match.enrollmentId)}` },
          },
        }]
      : []),
    {
      Put: {
        TableName: tableName,
        Item: {
          PK: `DEVICE#${deviceId}`,
          SK: "META",
          deviceId,
          name: deviceName,
          signingPublicKey: jsonWebKeyField(body, "signingPublicKey"),
          agreementPublicKey: jsonWebKeyField(body, "agreementPublicKey"),
          registeredAt,
          ...(ownerSub ? { ownerSub } : {}),
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
    ...(ownerSub
      ? [{
          Put: {
            TableName: tableName,
            Item: {
              PK: `USER#${ownerSub}`,
              SK: `DEVICE#${deviceId}`,
              deviceId,
              name: deviceName,
              registeredAt,
            },
            ConditionExpression: "attribute_not_exists(PK)",
          },
        }]
      : []),
  ];
  await dynamo.send(
    new TransactWriteCommand({
      TransactItems: transactItems,
    }),
  );
  return json(201, { deviceId, protocolVersion: 1, accountOwned: Boolean(ownerSub) });
}

async function claimDeviceForAccount(
  event: APIGatewayProxyEventV2,
): Promise<APIGatewayProxyStructuredResultV2> {
  const { principalId, principal } = await verifyAuthenticatedRequest(event);
  if (principal.deviceId !== principalId) {
    return json(403, { error: "Only a registered Mac can claim account ownership" });
  }
  const body = parseBody(event);
  const code = stringField(body, "code", 128);
  const enrollment = await dynamo.send(
    new GetCommand({
      TableName: tableName,
      Key: { PK: `ENROLLMENT#${sha256(code)}`, SK: "META" },
      ConsistentRead: true,
    }),
  );
  if (!enrollment.Item) {
    return json(401, { error: "Enrollment code is invalid or expired" });
  }
  if (
    Number(enrollment.Item.expiresAt) <= nowSeconds() ||
    !constantEqual(
      String(enrollment.Item.secretHash),
      saltedHash(String(enrollment.Item.salt), code),
    )
  ) {
    return json(401, { error: "Enrollment code is invalid or expired" });
  }
  if (typeof enrollment.Item.ownerSub !== "string") {
    // Operator enrollment codes do not change ownership, but they remain
    // single-use when presented by an already-registered Mac.
    await dynamo.send(
      new DeleteCommand({
        TableName: tableName,
        Key: { PK: enrollment.Item.PK, SK: enrollment.Item.SK },
        ConditionExpression: "secretHash = :hash",
        ExpressionAttributeValues: { ":hash": enrollment.Item.secretHash },
      }),
    );
    return json(200, { claimed: false });
  }
  const ownerSub = enrollment.Item.ownerSub;
  await dynamo.send(
    new TransactWriteCommand({
      TransactItems: [
        {
          Delete: {
            TableName: tableName,
            Key: { PK: enrollment.Item.PK, SK: enrollment.Item.SK },
            ConditionExpression: "secretHash = :hash",
            ExpressionAttributeValues: { ":hash": enrollment.Item.secretHash },
          },
        },
        {
          Delete: {
            TableName: tableName,
            Key: {
              PK: `USER#${ownerSub}`,
              SK: `ENROLLMENT#${String(enrollment.Item.enrollmentId)}`,
            },
          },
        },
        {
          Update: {
            TableName: tableName,
            Key: { PK: `DEVICE#${principalId}`, SK: "META" },
            UpdateExpression: "SET ownerSub = :owner",
            ConditionExpression:
              "deviceId = :device AND (attribute_not_exists(ownerSub) OR ownerSub = :owner)",
            ExpressionAttributeValues: {
              ":device": principalId,
              ":owner": ownerSub,
            },
          },
        },
        {
          Put: {
            TableName: tableName,
            Item: {
              PK: `USER#${ownerSub}`,
              SK: `DEVICE#${principalId}`,
              deviceId: principalId,
              name: String(principal.name ?? "Mac"),
              registeredAt: Number(principal.registeredAt ?? nowSeconds()),
            },
          },
        },
      ],
    }),
  );
  return json(200, { claimed: true });
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
  const ownerSub = typeof principal.ownerSub === "string" ? principal.ownerSub : undefined;
  const deviceName = String(principal.name ?? "Mac");
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
              ...(ownerSub ? { ownerSub } : {}),
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
              ...(ownerSub ? { ownerSub } : {}),
            },
          },
        },
        ...(ownerSub
          ? [{
              Put: {
                TableName: tableName,
                Item: {
                  PK: `USER#${ownerSub}`,
                  SK: `SESSION#${sessionId}`,
                  sessionId,
                  deviceId: principalId,
                  deviceName,
                  status: "active",
                  generation,
                  createdAt,
                  ttl,
                },
              },
            }]
          : []),
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
  if (
    !session.Item ||
    session.Item.deviceId !== principalId ||
    session.Item.status !== "active" ||
    Number(session.Item.ttl) <= nowSeconds() ||
    (typeof session.Item.ownerSub === "string" && session.Item.ownerSub !== principal.ownerSub)
  ) {
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
  if (!session.Item || session.Item.status !== "active" || Number(session.Item.ttl) <= nowSeconds()) {
    return json(410, { error: "Remote session ended" });
  }
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
      FilterExpression: "attribute_not_exists(revokedAt) AND #ttl > :now",
      ExpressionAttributeNames: { "#ttl": "ttl" },
      ExpressionAttributeValues: {
        ":pk": `SESSION#${sessionId}`,
        ":prefix": "CONTROLLER#",
        ":now": nowSeconds(),
      },
      Select: "COUNT",
      ConsistentRead: true,
    }),
  );
  const activeControllerCount = controllers.Count ?? 0;
  if (activeControllerCount >= 5) return json(429, { error: "This Mac already has five trusted controllers" });

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
            UpdateExpression: "SET controllerCount = :next",
            ConditionExpression:
              "#status = :active AND controllerCount = :observed",
            ExpressionAttributeNames: { "#status": "status" },
            ExpressionAttributeValues: {
              ":next": activeControllerCount + 1,
              ":observed": Number(session.Item.controllerCount ?? 0),
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

async function listAccountSessions(
  event: APIGatewayProxyEventV2,
): Promise<APIGatewayProxyStructuredResultV2> {
  const ownerSub = accountSubject(event);
  const items: Record<string, unknown>[] = [];
  let exclusiveStartKey: Record<string, unknown> | undefined;
  do {
    const result = await dynamo.send(
      new QueryCommand({
        TableName: tableName,
        KeyConditionExpression: "PK = :pk AND begins_with(SK, :prefix)",
        ExpressionAttributeValues: {
          ":pk": `USER#${ownerSub}`,
          ":prefix": "SESSION#",
        },
        ConsistentRead: true,
        ...(exclusiveStartKey ? { ExclusiveStartKey: exclusiveStartKey } : {}),
      }),
    );
    items.push(...(result.Items ?? []));
    exclusiveStartKey = result.LastEvaluatedKey;
  } while (exclusiveStartKey);
  return json(200, {
    sessions: items
      .filter((item) => item.status === "active" && Number(item.ttl) > nowSeconds())
      .map((item) => ({
        sessionId: String(item.sessionId),
        deviceId: String(item.deviceId),
        deviceName: String(item.deviceName ?? "Mac"),
        generation: Number(item.generation ?? 1),
        createdAt: Number(item.createdAt),
      }))
      .sort((left, right) => right.createdAt - left.createdAt),
  });
}

async function createAccountController(
  event: APIGatewayProxyEventV2,
  sessionId: string,
): Promise<APIGatewayProxyStructuredResultV2> {
  const ownerSub = accountSubject(event);
  const body = parseBody(event);
  if (Number(body.protocolVersion) !== 1) {
    return json(409, { error: "Protocol version incompatible" });
  }
  const browserId = stringField(body, "browserId", 128);
  const signingPublicKey = jsonWebKeyField(body, "signingPublicKey");
  const agreementPublicKey = jsonWebKeyField(body, "agreementPublicKey");
  const deviceName = stringField(body, "deviceName", 100);
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
    Number(session.Item.ttl) <= nowSeconds() ||
    session.Item.ownerSub !== ownerSub
  ) {
    // Deliberately do not reveal whether a session belongs to another tenant.
    return json(404, { error: "Active session not found" });
  }
  const mappingKey = {
    PK: `USER#${ownerSub}`,
    SK: `CONTROLLER#${sessionId}#${browserId}`,
  };
  const existingMapping = await dynamo.send(
    new GetCommand({ TableName: tableName, Key: mappingKey, ConsistentRead: true }),
  );
  if (existingMapping.Item?.controllerId) {
    const existing = await dynamo.send(
      new GetCommand({
        TableName: tableName,
        Key: { PK: `CONTROLLER#${String(existingMapping.Item.controllerId)}`, SK: "META" },
        ConsistentRead: true,
      }),
    );
    if (
      existing.Item &&
      !existing.Item.revokedAt &&
      Number(existing.Item.ttl) > nowSeconds() &&
      existing.Item.ownerSub === ownerSub &&
      existing.Item.sessionId === sessionId
    ) {
      const existingSigning = existing.Item.signingPublicKey as JsonWebKey;
      const existingAgreement = existing.Item.agreementPublicKey as JsonWebKey;
      if (
        existingSigning.x !== signingPublicKey.x ||
        existingSigning.y !== signingPublicKey.y ||
        existingAgreement.x !== agreementPublicKey.x ||
        existingAgreement.y !== agreementPublicKey.y
      ) {
        return json(409, { error: "This browser identity changed; clear its saved account access and try again" });
      }
      return json(200, {
        controllerId: String(existing.Item.controllerId),
        sessionId,
        generation: Number(session.Item.generation),
        protocolVersion: 1,
        keySalt: String(existing.Item.keySalt),
        macAgreementPublicKey: session.Item.agreementPublicKey,
      });
    }
    if (existing.Item?.revokedAt) {
      return json(403, { error: "This browser was revoked; clear its saved site data before registering it again" });
    }
    try {
      await dynamo.send(
        new DeleteCommand({
          TableName: tableName,
          Key: mappingKey,
          ConditionExpression: "controllerId = :controller",
          ExpressionAttributeValues: {
            ":controller": existingMapping.Item.controllerId,
          },
        }),
      );
    } catch {
      return json(409, { error: "Browser registration changed; try again" });
    }
  }
  const controllers = await dynamo.send(
    new QueryCommand({
      TableName: tableName,
      KeyConditionExpression: "PK = :pk AND begins_with(SK, :prefix)",
      FilterExpression: "attribute_not_exists(revokedAt) AND #ttl > :now",
      ExpressionAttributeNames: { "#ttl": "ttl" },
      ExpressionAttributeValues: {
        ":pk": `SESSION#${sessionId}`,
        ":prefix": "CONTROLLER#",
        ":now": nowSeconds(),
      },
      Select: "COUNT",
      ConsistentRead: true,
    }),
  );
  const activeControllerCount = controllers.Count ?? 0;
  if (activeControllerCount >= 5) {
    return json(429, { error: "This Mac already has five trusted controllers" });
  }
  const controllerId = crypto.randomUUID();
  const keySalt = randomSecret(32);
  const createdAt = nowSeconds();
  const ttl = createdAt + ACTIVE_SESSION_TTL_SECONDS;
  const controller = {
    controllerId,
    sessionId,
    deviceId: session.Item.deviceId,
    ownerSub,
    browserId,
    accessMode: "account",
    keySalt,
    name: deviceName,
    signingPublicKey,
    agreementPublicKey,
    createdAt,
    ttl,
  };
  await dynamo.send(
    new TransactWriteCommand({
      TransactItems: [
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
          Put: {
            TableName: tableName,
            Item: { ...mappingKey, controllerId, sessionId, browserId, createdAt, ttl },
            ConditionExpression: "attribute_not_exists(PK)",
          },
        },
        {
          Update: {
            TableName: tableName,
            Key: { PK: `SESSION#${sessionId}`, SK: "META" },
            UpdateExpression: "SET controllerCount = :next",
            ConditionExpression:
              "#status = :active AND ownerSub = :owner AND controllerCount = :observed",
            ExpressionAttributeNames: { "#status": "status" },
            ExpressionAttributeValues: {
              ":next": activeControllerCount + 1,
              ":observed": Number(session.Item.controllerCount ?? 0),
              ":active": "active",
              ":owner": ownerSub,
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
    keySalt,
    macAgreementPublicKey: session.Item.agreementPublicKey,
  });
}

async function createTicket(
  event: APIGatewayProxyEventV2,
  requiredOwnerSub?: string,
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
  if (!session.Item || session.Item.status !== "active" || Number(session.Item.ttl) <= nowSeconds()) {
    return json(410, { error: "Remote session ended" });
  }
  if (role === "mac" && session.Item.deviceId !== principalId) return json(403, { error: "Cross-session ticket rejected" });
  if (role === "controller" && principal.accessMode === "account") {
    if (!requiredOwnerSub) return json(401, { error: "Account authentication required" });
    if (!accountTenantMatches({
      controllerOwnerSub: principal.ownerSub,
      sessionOwnerSub: session.Item.ownerSub,
      assertedOwnerSub: requiredOwnerSub,
    })) {
      return json(403, { error: "Cross-tenant ticket rejected" });
    }
  } else if (requiredOwnerSub) {
    return json(403, { error: "Account ticket requires an account controller" });
  }

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
    ...(typeof session.Item.ownerSub === "string"
      ? [{
          Update: {
            TableName: tableName,
            Key: { PK: `USER#${String(session.Item.ownerSub)}`, SK: `SESSION#${sessionId}` },
            UpdateExpression: "SET #ttl = :ttl",
            ConditionExpression: "#status = :active",
            ExpressionAttributeNames: { "#status": "status", "#ttl": "ttl" },
            ExpressionAttributeValues: { ":ttl": sessionTtl, ":active": "active" },
          },
        }]
      : []),
    ...(role === "controller" && principal.accessMode === "account"
      ? [{
          Update: {
            TableName: tableName,
            Key: {
              PK: `USER#${String(principal.ownerSub)}`,
              SK: `CONTROLLER#${sessionId}#${String(principal.browserId)}`,
            },
            UpdateExpression: "SET #ttl = :ttl",
            ExpressionAttributeNames: { "#ttl": "ttl" },
            ExpressionAttributeValues: { ":ttl": sessionTtl },
          },
        }]
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
              ...(requiredOwnerSub ? { ownerSub: requiredOwnerSub } : {}),
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
  if (typeof principal.ownerSub === "string") {
    await dynamo.send(
      new UpdateCommand({
        TableName: tableName,
        Key: { PK: `USER#${principal.ownerSub}`, SK: `SESSION#${sessionId}` },
        UpdateExpression: "SET #status = :ended, endedAt = :now, #ttl = :ttl",
        ExpressionAttributeNames: { "#status": "status", "#ttl": "ttl" },
        ExpressionAttributeValues: {
          ":ended": "ended",
          ":now": endedAt,
          ":ttl": endedAt + ENDED_RECORD_TTL_SECONDS,
        },
      }),
    );
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
    controller.Item.revokedAt ||
    Number(controller.Item.ttl) <= nowSeconds() ||
    (controller.Item.accessMode === "account" &&
      !accountTenantMatches({
        controllerOwnerSub: controller.Item.ownerSub,
        sessionOwnerSub: session.Item.ownerSub,
        assertedOwnerSub: principal.ownerSub,
      }))
  ) {
    return json(404, { error: "Trusted controller not found" });
  }
  return json(200, {
    controllerId,
    accessMode: controller.Item.accessMode ?? "pairing",
    ...(controller.Item.pairingId ? { pairingId: controller.Item.pairingId } : {}),
    ...(controller.Item.keySalt ? { keySalt: controller.Item.keySalt } : {}),
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
      accountAuth: cognitoAuthEnabled && cognitoClientId && cognitoDomain && cognitoIssuer
        ? {
            clientId: cognitoClientId,
            domain: cognitoDomain,
            issuer: cognitoIssuer,
            callbackPath: "/auth/callback",
          }
        : undefined,
      mockMode: false,
    });
  }
  if (method === "GET") {
    if (path === "/api/v1/account/sessions") return listAccountSessions(event);
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
  if (path === "/api/v1/account/enrollments") {
    return json(201, await createEnrollment(accountSubject(event)));
  }
  if (path === "/api/v1/account/tickets") {
    return createTicket(event, accountSubject(event));
  }
  const accountControllerMatch = path.match(
    /^\/api\/v1\/account\/sessions\/([^/]+)\/controllers$/u,
  );
  if (accountControllerMatch?.[1]) {
    return createAccountController(event, decodeURIComponent(accountControllerMatch[1]));
  }
  if (path === "/api/v1/enrollments/redeem") return redeemEnrollment(event);
  if (path === "/api/v1/devices/claim") return claimDeviceForAccount(event);
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
