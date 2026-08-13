import {
  ApiGatewayManagementApiClient,
  DeleteConnectionCommand,
} from "@aws-sdk/client-apigatewaymanagementapi";
import {
  AdminDeleteUserCommand,
  AdminSetUserPasswordCommand,
  AdminUserGlobalSignOutCommand,
  CognitoIdentityProviderClient,
} from "@aws-sdk/client-cognito-identity-provider";
import {
  BatchWriteCommand,
  type BatchWriteCommandInput,
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
  verifyP256Signature,
} from "./common.js";

interface AdminEnrollmentEvent {
  readonly action: "createEnrollment";
}

const pairingDisabled = process.env.DISABLE_NEW_PAIRINGS === "true";
const ACTIVE_SESSION_TTL_SECONDS = 24 * 60 * 60;
const ENDED_RECORD_TTL_SECONDS = 7 * 24 * 60 * 60;
const ACCOUNT_DELETION_TTL_SECONDS = 2 * 60 * 60;
const ACCOUNT_BOOTSTRAP_TTL_SECONDS = 20 * 60;
const ACCOUNT_PASSWORD_RESET_TTL_SECONDS = 10 * 60;
const RECENT_ACCOUNT_AUTH_SECONDS = 5 * 60;
const publicRegion = process.env.AWS_REGION ?? "us-west-2";
const stage = process.env.STAGE ?? "dev";
const publicWebSocketUrl = process.env.PUBLIC_WEBSOCKET_URL ?? "";
const cognitoAuthEnabled = process.env.COGNITO_AUTH_ENABLED === "true";
const cognitoClientId = process.env.COGNITO_CLIENT_ID ?? "";
const cognitoDomain = process.env.COGNITO_DOMAIN ?? "";
const cognitoIssuer = process.env.COGNITO_ISSUER ?? "";
const cognitoUserPoolId = process.env.COGNITO_USER_POOL_ID ?? "";
const cognito = new CognitoIdentityProviderClient({});
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

function accountIdentity(event: APIGatewayProxyEventV2): {
  readonly sub: string;
  readonly username?: string;
  readonly issuedAt?: number;
} {
  const context = event.requestContext as typeof event.requestContext & {
    authorizer?: { jwt?: { claims?: Record<string, string | number | boolean | string[]> } };
  };
  const authorizer = context.authorizer;
  const sub = authorizer?.jwt?.claims?.sub;
  const username = authorizer?.jwt?.claims?.username;
  const tokenUse = authorizer?.jwt?.claims?.token_use;
  const issuedAt = authorizer?.jwt?.claims?.iat;
  if (
    tokenUse !== "access" ||
    typeof sub !== "string" ||
    !/^[\w-]{8,128}$/u.test(sub)
  ) {
    throw new Error("Account authentication required");
  }
  return {
    sub,
    ...(typeof username === "string" && username.length > 0 && username.length <= 128
      ? { username }
      : {}),
    ...(typeof issuedAt === "number" && Number.isSafeInteger(issuedAt)
      ? { issuedAt }
      : typeof issuedAt === "string" && /^\d+$/u.test(issuedAt)
        ? { issuedAt: Number(issuedAt) }
        : {}),
  };
}

function accountSubject(event: APIGatewayProxyEventV2): string {
  return accountIdentity(event).sub;
}

function recentAccountIdentity(event: APIGatewayProxyEventV2): {
  readonly sub: string;
  readonly username?: string;
  readonly issuedAt: number;
} {
  const identity = accountIdentity(event);
  const now = nowSeconds();
  if (
    identity.issuedAt === undefined ||
    identity.issuedAt > now + 60 ||
    identity.issuedAt < now - RECENT_ACCOUNT_AUTH_SECONDS
  ) {
    throw new Error("Recent account authentication required");
  }
  return { ...identity, issuedAt: identity.issuedAt };
}

async function assertAccountActive(ownerSub: string, issuedAt?: number): Promise<void> {
  const [deletion, account] = await Promise.all([
    dynamo.send(new GetCommand({
      TableName: tableName,
      Key: { PK: `USER#${ownerSub}`, SK: "ACCOUNT#DELETED" },
      ConsistentRead: true,
    })),
    issuedAt === undefined
      ? Promise.resolve({ Item: undefined })
      : dynamo.send(new GetCommand({
          TableName: tableName,
          Key: { PK: `USER#${ownerSub}`, SK: "ACCOUNT#META" },
          ConsistentRead: true,
        })),
  ]);
  if (deletion.Item) throw new Error("Account has been deleted");
  if (
    issuedAt !== undefined &&
    Number(account.Item?.credentialsChangedAt ?? 0) >= issuedAt
  ) {
    throw new Error("Account credentials changed. Sign in again.");
  }
}

function accountActiveCondition(
  ownerSub: string | undefined,
): NonNullable<TransactWriteCommandInput["TransactItems"]> {
  return ownerSub
    ? [{
        ConditionCheck: {
          TableName: tableName,
          Key: { PK: `USER#${ownerSub}`, SK: "ACCOUNT#DELETED" },
          ConditionExpression: "attribute_not_exists(PK)",
        },
      }]
    : [];
}

interface AccountBootstrapProof {
  readonly fingerprint: string;
  readonly deviceName: string;
  readonly signingPublicKey: JsonWebKey;
  readonly agreementPublicKey: JsonWebKey;
  readonly previousDeviceId?: string;
  readonly nonce?: string;
}

async function accountBootstrapProof(
  event: APIGatewayProxyEventV2,
  body: Record<string, unknown>,
): Promise<AccountBootstrapProof> {
  const principalHeader = Object.entries(event.headers).find(
    ([name]) => name.toLowerCase() === "x-terminaldb-principal",
  )?.[1];
  if (principalHeader) {
    const { principalId, principal } = await verifyAuthenticatedRequest(event);
    if (principal.deviceId !== principalId) {
      throw new Error("Only a TerminalDB Mac can approve account creation");
    }
    if (typeof principal.ownerSub === "string") {
      throw new Error("This Mac is already connected to a TerminalDB account");
    }
    const signingPublicKey = principal.signingPublicKey as JsonWebKey;
    const agreementPublicKey = principal.agreementPublicKey as JsonWebKey;
    return {
      fingerprint: sha256(`${signingPublicKey.x}.${signingPublicKey.y}`),
      deviceName: String(principal.name ?? "Mac").slice(0, 100),
      signingPublicKey,
      agreementPublicKey,
      previousDeviceId: principalId,
    };
  }

  const timestamp = Number(body.timestamp);
  const nonce = stringField(body, "nonce", 128);
  const deviceName = stringField(body, "deviceName", 100);
  const signature = stringField(body, "signature", 256);
  const signingPublicKey = jsonWebKeyField(body, "signingPublicKey");
  const agreementPublicKey = jsonWebKeyField(body, "agreementPublicKey");
  if (!Number.isSafeInteger(timestamp) || Math.abs(Date.now() - timestamp) > 60_000) {
    throw new Error("Stale account bootstrap proof");
  }
  const canonical = [
    String(timestamp),
    nonce,
    deviceName,
    signingPublicKey.x,
    signingPublicKey.y,
    agreementPublicKey.x,
    agreementPublicKey.y,
  ].join("\n");
  if (!verifyP256Signature(signingPublicKey, canonical, signature)) {
    throw new Error("Invalid account bootstrap signature");
  }
  return {
    fingerprint: sha256(`${signingPublicKey.x}.${signingPublicKey.y}`),
    deviceName,
    signingPublicKey,
    agreementPublicKey,
    nonce,
  };
}

async function createAccountBootstrap(
  event: APIGatewayProxyEventV2,
): Promise<APIGatewayProxyStructuredResultV2> {
  if (!cognitoClientId) throw new Error("Account creation is not configured");
  const body = parseBody(event);
  const proof = await accountBootstrapProof(event, body);
  const token = randomSecret(32);
  const now = nowSeconds();
  const expiresAt = now + ACCOUNT_BOOTSTRAP_TTL_SECONDS;
  const transactItems: NonNullable<TransactWriteCommandInput["TransactItems"]> = [
    ...(proof.nonce
      ? [{
          Put: {
            TableName: tableName,
            Item: {
              PK: `BOOTSTRAP_NONCE#${proof.fingerprint}`,
              SK: proof.nonce,
              ttl: now + 120,
            },
            ConditionExpression: "attribute_not_exists(PK)",
          },
        }]
      : []),
    {
      Put: {
        TableName: tableName,
        Item: {
          PK: `BOOTSTRAP_RATE#${proof.fingerprint}`,
          SK: "META",
          ttl: now + 60,
        },
        ConditionExpression: "attribute_not_exists(PK) OR #ttl < :now",
        ExpressionAttributeNames: { "#ttl": "ttl" },
        ExpressionAttributeValues: { ":now": now },
      },
    },
    {
      Put: {
        TableName: tableName,
        Item: {
          PK: `ACCOUNT_BOOTSTRAP#${sha256(token)}`,
          SK: "META",
          status: "pending",
          clientId: cognitoClientId,
          deviceName: proof.deviceName,
          signingPublicKey: proof.signingPublicKey,
          agreementPublicKey: proof.agreementPublicKey,
          createdAt: now,
          expiresAt,
          ttl: expiresAt,
          ...(proof.previousDeviceId
            ? { previousDeviceId: proof.previousDeviceId }
            : {}),
        },
        ConditionExpression: "attribute_not_exists(PK)",
      },
    },
  ];
  await dynamo.send(new TransactWriteCommand({ TransactItems: transactItems }));
  return json(201, { bootstrapToken: token, expiresAt });
}

async function accountBootstrapStatus(
  event: APIGatewayProxyEventV2,
): Promise<APIGatewayProxyStructuredResultV2> {
  const body = parseBody(event);
  const token = stringField(body, "bootstrapToken", 256);
  const result = await dynamo.send(
    new GetCommand({
      TableName: tableName,
      Key: { PK: `ACCOUNT_BOOTSTRAP#${sha256(token)}`, SK: "META" },
      ConsistentRead: true,
    }),
  );
  if (!result.Item || Number(result.Item.ttl) <= nowSeconds()) {
    return json(410, { error: "Account setup ended. Start again when you are ready." });
  }
  if (result.Item.status === "complete" && result.Item.deviceId) {
    return json(200, { status: "complete", deviceId: result.Item.deviceId });
  }
  return json(200, { status: "pending" });
}

async function cancelAccountBootstrap(
  event: APIGatewayProxyEventV2,
): Promise<APIGatewayProxyStructuredResultV2> {
  const body = parseBody(event);
  const token = stringField(body, "bootstrapToken", 256);
  const key = { PK: `ACCOUNT_BOOTSTRAP#${sha256(token)}`, SK: "META" };
  let bootstrap: Record<string, unknown> | undefined;
  try {
    const deleted = await dynamo.send(new DeleteCommand({
      TableName: tableName,
      Key: key,
      ConditionExpression: "#status <> :complete AND #ttl > :now",
      ExpressionAttributeNames: { "#status": "status", "#ttl": "ttl" },
      ExpressionAttributeValues: { ":complete": "complete", ":now": nowSeconds() },
      ReturnValues: "ALL_OLD",
    }));
    bootstrap = deleted.Attributes;
  } catch (error) {
    if ((error as { name?: string }).name === "ConditionalCheckFailedException") {
      const current = await dynamo.send(new GetCommand({
        TableName: tableName,
        Key: key,
        ConsistentRead: true,
      }));
      if (current.Item?.status === "complete") {
        return json(409, { error: "Account setup already completed" });
      }
      return json(410, { error: "Account setup already ended" });
    }
    throw error;
  }
  if (!bootstrap) return json(410, { error: "Account setup already ended" });
  if (
    bootstrap.status === "signup-confirmed" &&
    typeof bootstrap.cognitoUsername === "string" &&
    cognitoUserPoolId
  ) {
    try {
      await cognito.send(new AdminDeleteUserCommand({
        UserPoolId: cognitoUserPoolId,
        Username: bootstrap.cognitoUsername,
      }));
    } catch (error) {
      if ((error as { name?: string }).name !== "UserNotFoundException") throw error;
    }
  }
  return json(200, { canceled: true });
}

async function createAccountPasswordReset(
  event: APIGatewayProxyEventV2,
): Promise<APIGatewayProxyStructuredResultV2> {
  if (!cognitoUserPoolId) throw new Error("Account recovery is not configured");
  const { principalId, principal } = await verifyAuthenticatedRequest(event);
  if (principal.deviceId !== principalId || typeof principal.ownerSub !== "string") {
    throw new Error("Only an enrolled TerminalDB Mac can reset this account password");
  }
  const ownerSub = principal.ownerSub;
  await assertAccountActive(ownerSub);
  const account = await dynamo.send(new GetCommand({
    TableName: tableName,
    Key: { PK: `USER#${ownerSub}`, SK: "ACCOUNT#META" },
    ConsistentRead: true,
  }));
  const username = account.Item?.username;
  if (typeof username !== "string" || username.length === 0 || username.length > 128) {
    throw new Error("This Mac is not connected to an active TerminalDB account");
  }

  const resetToken = randomSecret(32);
  const now = nowSeconds();
  const expiresAt = now + ACCOUNT_PASSWORD_RESET_TTL_SECONDS;
  await dynamo.send(new TransactWriteCommand({
    TransactItems: [
      {
        ConditionCheck: {
          TableName: tableName,
          Key: { PK: `USER#${ownerSub}`, SK: "ACCOUNT#DELETED" },
          ConditionExpression: "attribute_not_exists(PK)",
        },
      },
      {
        Put: {
          TableName: tableName,
          Item: {
            PK: `ACCOUNT_PASSWORD_RESET#${sha256(resetToken)}`,
            SK: "META",
            ownerSub,
            accountUsername: username,
            deviceId: principalId,
            createdAt: now,
            expiresAt,
            ttl: expiresAt,
          },
          ConditionExpression: "attribute_not_exists(PK)",
        },
      },
    ],
  }));
  return json(201, { resetToken, expiresAt });
}

async function redeemAccountPasswordReset(
  event: APIGatewayProxyEventV2,
): Promise<APIGatewayProxyStructuredResultV2> {
  if (!cognitoUserPoolId) throw new Error("Account recovery is not configured");
  const body = parseBody(event);
  const resetToken = stringField(body, "resetToken", 256);
  let grant: Record<string, unknown> | undefined;
  try {
    const consumed = await dynamo.send(new DeleteCommand({
      TableName: tableName,
      Key: { PK: `ACCOUNT_PASSWORD_RESET#${sha256(resetToken)}`, SK: "META" },
      ConditionExpression: "#ttl > :now",
      ExpressionAttributeNames: { "#ttl": "ttl" },
      ExpressionAttributeValues: { ":now": nowSeconds() },
      ReturnValues: "ALL_OLD",
    }));
    grant = consumed.Attributes;
  } catch (error) {
    if ((error as { name?: string }).name !== "ConditionalCheckFailedException") throw error;
  }
  if (!grant) {
    return json(410, { error: "Password reset approval expired or was already used. Start again from TerminalDB on your Mac." });
  }
  const username = grant.accountUsername;
  const ownerSub = grant.ownerSub;
  if (typeof username !== "string" || typeof ownerSub !== "string") {
    throw new Error("Password reset approval is invalid");
  }

  // The browser uses this high-entropy temporary password only to enter
  // Cognito's NEW_PASSWORD_REQUIRED flow. The user's chosen replacement
  // password and TOTP code continue to go directly from browser to Cognito.
  const temporaryPassword = `Tdb-${randomSecret(32)}-9aA!`;
  await cognito.send(new AdminSetUserPasswordCommand({
    UserPoolId: cognitoUserPoolId,
    Username: username,
    Password: temporaryPassword,
    Permanent: false,
  }));
  await cognito.send(new AdminUserGlobalSignOutCommand({
    UserPoolId: cognitoUserPoolId,
    Username: username,
  }));
  const changedAt = nowSeconds();
  await dynamo.send(new UpdateCommand({
    TableName: tableName,
    Key: { PK: `USER#${ownerSub}`, SK: "ACCOUNT#META" },
    UpdateExpression: "SET credentialsChangedAt = :now",
    ConditionExpression: "attribute_exists(PK) AND username = :username",
    ExpressionAttributeValues: { ":now": changedAt, ":username": username },
  }));
  await revokeAccountControllers(ownerSub);
  return json(200, { username, temporaryPassword });
}

async function completeAccountBootstrap(
  event: APIGatewayProxyEventV2,
): Promise<APIGatewayProxyStructuredResultV2> {
  const { sub: ownerSub, username } = accountIdentity(event);
  if (!username) throw new Error("Account username claim is missing");
  const body = parseBody(event);
  const token = stringField(body, "bootstrapToken", 256);
  const key = { PK: `ACCOUNT_BOOTSTRAP#${sha256(token)}`, SK: "META" };
  const result = await dynamo.send(
    new GetCommand({ TableName: tableName, Key: key, ConsistentRead: true }),
  );
  const bootstrap = result.Item;
  if (!bootstrap || Number(bootstrap.ttl) <= nowSeconds()) {
    return json(410, { error: "Account setup expired. Start again from TerminalDB." });
  }
  if (bootstrap.status === "complete") {
    if (bootstrap.ownerSub !== ownerSub) {
      return json(403, { error: "This account setup belongs to another account" });
    }
    return json(200, { completed: true, deviceId: bootstrap.deviceId });
  }
  const pendingManagedLoginCompletion = bootstrap.status === "pending";
  const approvedSignupCompletion = (
    (bootstrap.status === "signup-prepared" || bootstrap.status === "signup-confirmed") &&
    typeof bootstrap.cognitoUsername === "string" &&
    constantEqual(bootstrap.cognitoUsername, username)
  );
  if (!pendingManagedLoginCompletion && !approvedSignupCompletion) {
    return json(403, { error: "Complete the approved Cognito signup before connecting this Mac" });
  }
  let existingAccountConnection = false;
  if (pendingManagedLoginCompletion) {
    recentAccountIdentity(event);
    const account = await dynamo.send(new GetCommand({
      TableName: tableName,
      Key: { PK: `USER#${ownerSub}`, SK: "ACCOUNT#META" },
      ConsistentRead: true,
    }));
    if (account.Item) {
      if (!constantEqual(String(account.Item.username ?? ""), username)) {
        return json(403, { error: "This account identity does not match its TerminalDB record" });
      }
      existingAccountConnection = true;
      await assertAccountActive(ownerSub);
    }
  }
  const deviceId = typeof bootstrap.previousDeviceId === "string"
    ? bootstrap.previousDeviceId
    : crypto.randomUUID();
  const completedAt = nowSeconds();
  const deviceRecord = {
    deviceId,
    name: String(bootstrap.deviceName ?? "Mac"),
    signingPublicKey: bootstrap.signingPublicKey,
    agreementPublicKey: bootstrap.agreementPublicKey,
    ownerSub,
    registeredAt: completedAt,
  };
  const deviceWrite = typeof bootstrap.previousDeviceId === "string"
    ? {
        Update: {
          TableName: tableName,
          Key: { PK: `DEVICE#${deviceId}`, SK: "META" },
          UpdateExpression: "SET ownerSub = :owner, #name = :name REMOVE #ttl, #temporary",
          ConditionExpression:
            "attribute_exists(PK) AND (attribute_not_exists(ownerSub) OR ownerSub = :owner)",
          ExpressionAttributeNames: {
            "#name": "name",
            "#ttl": "ttl",
            "#temporary": "temporary",
          },
          ExpressionAttributeValues: {
            ":owner": ownerSub,
            ":name": deviceRecord.name,
          },
        },
      }
    : {
        Put: {
          TableName: tableName,
          Item: { PK: `DEVICE#${deviceId}`, SK: "META", ...deviceRecord },
          ConditionExpression: "attribute_not_exists(PK)",
        },
      };
  await dynamo.send(
    new TransactWriteCommand({
      TransactItems: [
        {
          Update: {
            TableName: tableName,
            Key: key,
            UpdateExpression:
              "SET #status = :complete, ownerSub = :owner, deviceId = :device, completedAt = :now, #ttl = :ttl",
            ConditionExpression: pendingManagedLoginCompletion
              ? "#status = :pending AND #ttl > :now"
              : "(#status = :prepared OR #status = :confirmed) AND cognitoUsername = :username AND #ttl > :now",
            ExpressionAttributeNames: { "#status": "status", "#ttl": "ttl" },
            ExpressionAttributeValues: {
              ":complete": "complete",
              ":owner": ownerSub,
              ":device": deviceId,
              ":now": completedAt,
              ":ttl": completedAt + 5 * 60,
              ...(pendingManagedLoginCompletion
                ? { ":pending": "pending" }
                : {
                    ":prepared": "signup-prepared",
                    ":confirmed": "signup-confirmed",
                    ":username": username,
                  }),
            },
          },
        },
        deviceWrite,
        {
          Put: {
            TableName: tableName,
            Item: {
              PK: `USER#${ownerSub}`,
              SK: `DEVICE#${deviceId}`,
              deviceId,
              name: deviceRecord.name,
              registeredAt: completedAt,
              lastSeenAt: completedAt,
              status: "offline",
            },
            ConditionExpression: "attribute_not_exists(PK)",
          },
        },
        {
          ...(existingAccountConnection
            ? {
                ConditionCheck: {
                  TableName: tableName,
                  Key: { PK: `USER#${ownerSub}`, SK: "ACCOUNT#META" },
                  ConditionExpression: "attribute_exists(PK) AND username = :username",
                  ExpressionAttributeValues: { ":username": username },
                },
              }
            : {
                Put: {
                  TableName: tableName,
                  Item: {
                    PK: `USER#${ownerSub}`,
                    SK: "ACCOUNT#META",
                    username,
                    createdAt: completedAt,
                    recovery: "authenticator-app-only",
                  },
                  ConditionExpression: "attribute_not_exists(PK)",
                },
              }),
        },
        ...accountActiveCondition(ownerSub),
      ],
    }),
  );
  return json(200, { completed: true, deviceId });
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
    codeHash: sha256(code),
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
        ...accountActiveCondition(ownerSub),
      ],
    }),
  );
  return { enrollmentCode: code, expiresAt };
}

async function queryPartition(partitionKey: string): Promise<Record<string, unknown>[]> {
  const items: Record<string, unknown>[] = [];
  let exclusiveStartKey: Record<string, unknown> | undefined;
  do {
    const result = await dynamo.send(
      new QueryCommand({
        TableName: tableName,
        KeyConditionExpression: "PK = :pk",
        ExpressionAttributeValues: { ":pk": partitionKey },
        ConsistentRead: true,
        ...(exclusiveStartKey ? { ExclusiveStartKey: exclusiveStartKey } : {}),
      }),
    );
    items.push(...(result.Items ?? []));
    exclusiveStartKey = result.LastEvaluatedKey;
  } while (exclusiveStartKey);
  return items;
}

async function batchDelete(keys: readonly { readonly PK: string; readonly SK: string }[]): Promise<void> {
  const unique = [...new Map(keys.map((key) => [`${key.PK}\u0000${key.SK}`, key])).values()];
  for (let offset = 0; offset < unique.length; offset += 25) {
    let pending: NonNullable<BatchWriteCommandInput["RequestItems"]>[string] =
      unique.slice(offset, offset + 25).map((Key) => ({ DeleteRequest: { Key } }));
    for (let attempt = 0; pending.length > 0 && attempt < 6; attempt += 1) {
      const result = await dynamo.send(
        new BatchWriteCommand({ RequestItems: { [tableName]: pending } }),
      );
      pending = result.UnprocessedItems?.[tableName] ?? [];
    }
    if (pending.length > 0) throw new Error("Account data deletion could not be completed");
  }
}

async function revokeAccountControllers(ownerSub: string): Promise<void> {
  const userItems = await queryPartition(`USER#${ownerSub}`);
  const mappings = userItems.filter(
    (item) =>
      String(item.SK).startsWith("CONTROLLER#") &&
      typeof item.controllerId === "string" &&
      typeof item.sessionId === "string",
  );
  if (mappings.length === 0) return;

  const sessionIds = [...new Set(mappings.map((item) => String(item.sessionId)))];
  const accountControllerIds = new Set(mappings.map((item) => String(item.controllerId)));
  const sessionPartitions = await Promise.all(
    sessionIds.map((sessionId) => queryPartition(`SESSION#${sessionId}`)),
  );
  const connectionIds: string[] = [];
  const keys = mappings.map((item) => ({ PK: String(item.PK), SK: String(item.SK) }));

  for (let index = 0; index < sessionIds.length; index += 1) {
    const sessionId = sessionIds[index];
    const items = sessionPartitions[index] ?? [];
    const sessionControllerIds = new Set(
      mappings
        .filter((item) => String(item.sessionId) === sessionId)
        .map((item) => String(item.controllerId)),
    );
    for (const controllerId of sessionControllerIds) {
      keys.push(
        { PK: `CONTROLLER#${controllerId}`, SK: "META" },
        { PK: `SESSION#${sessionId}`, SK: `CONTROLLER#${controllerId}` },
      );
    }
    for (const item of items) {
      if (
        String(item.SK).startsWith("SOCKET#controller#") &&
        accountControllerIds.has(String(item.clientId))
      ) {
        keys.push({ PK: String(item.PK), SK: String(item.SK) });
        if (typeof item.connectionId === "string") {
          connectionIds.push(item.connectionId);
          keys.push({ PK: `CONNECTION#${item.connectionId}`, SK: "META" });
        }
      }
    }
    const remainingControllers = items.filter(
      (item) =>
        String(item.SK).startsWith("CONTROLLER#") &&
        !sessionControllerIds.has(String(item.controllerId)) &&
        !item.revokedAt &&
        Number(item.ttl) > nowSeconds(),
    ).length;
    await dynamo.send(new UpdateCommand({
      TableName: tableName,
      Key: { PK: `SESSION#${sessionId}`, SK: "META" },
      UpdateExpression: "SET controllerCount = :count",
      ConditionExpression: "attribute_exists(PK)",
      ExpressionAttributeValues: { ":count": remainingControllers },
    }));
  }

  await batchDelete(keys);
  await disconnectConnections([...new Set(connectionIds)]);
}

async function deleteAccountData(
  ownerSub: string,
  username: string,
): Promise<APIGatewayProxyStructuredResultV2> {
  if (!cognitoUserPoolId) throw new Error("Account deletion is not configured");
  const deletedAt = nowSeconds();
  await dynamo.send(
    new UpdateCommand({
      TableName: tableName,
      Key: { PK: `USER#${ownerSub}`, SK: "ACCOUNT#DELETED" },
      UpdateExpression: "SET deletedAt = if_not_exists(deletedAt, :now), #ttl = :ttl",
      ExpressionAttributeNames: { "#ttl": "ttl" },
      ExpressionAttributeValues: {
        ":now": deletedAt,
        ":ttl": deletedAt + ACCOUNT_DELETION_TTL_SECONDS,
      },
    }),
  );

  const userItems = await queryPartition(`USER#${ownerSub}`);
  const sessionIds = [...new Set(userItems.flatMap((item) =>
    typeof item.sessionId === "string" && String(item.SK).startsWith("SESSION#")
      ? [item.sessionId]
      : [],
  ))];
  const deviceIds = [...new Set(userItems.flatMap((item) =>
    typeof item.deviceId === "string" && String(item.SK).startsWith("DEVICE#")
      ? [item.deviceId]
      : [],
  ))];
  const [sessionPartitions, devicePartitions] = await Promise.all([
    Promise.all(sessionIds.map((sessionId) => queryPartition(`SESSION#${sessionId}`))),
    Promise.all(deviceIds.map((deviceId) => queryPartition(`DEVICE#${deviceId}`))),
  ]);
  const sessionItems = sessionPartitions.flat();
  const connectionIds = [...new Set(sessionItems.flatMap((item) =>
    typeof item.connectionId === "string" && String(item.SK).startsWith("SOCKET#")
      ? [item.connectionId]
      : [],
  ))];
  const controllerIds = [...new Set([
    ...userItems.flatMap((item) =>
      typeof item.controllerId === "string" ? [item.controllerId] : [],
    ),
    ...sessionItems.flatMap((item) =>
      typeof item.controllerId === "string" ? [item.controllerId] : [],
    ),
  ])];
  const pairingIds = [...new Set(sessionItems.flatMap((item) =>
    typeof item.pairingId === "string" ? [item.pairingId] : [],
  ))];
  const enrollmentHashes = [...new Set(userItems.flatMap((item) =>
    typeof item.codeHash === "string" ? [item.codeHash] : [],
  ))];
  const directKeys = [
    ...controllerIds.map((controllerId) => ({ PK: `CONTROLLER#${controllerId}`, SK: "META" })),
    ...pairingIds.map((pairingId) => ({ PK: `PAIRING#${pairingId}`, SK: "META" })),
    ...enrollmentHashes.map((hash) => ({ PK: `ENROLLMENT#${hash}`, SK: "META" })),
    ...connectionIds.map((connectionId) => ({ PK: `CONNECTION#${connectionId}`, SK: "META" })),
  ];
  const ownedPartitionKeys = [
    ...sessionItems.map((item) => ({ PK: String(item.PK), SK: String(item.SK) })),
    ...devicePartitions.flat().map((item) => ({ PK: String(item.PK), SK: String(item.SK) })),
  ];
  const userKeys = userItems
    .filter((item) => item.SK !== "ACCOUNT#DELETED")
    .map((item) => ({ PK: String(item.PK), SK: String(item.SK) }));
  // Keep the user indexes until their direct records are gone so a retry can
  // rediscover every owned partition after a partially throttled batch.
  await batchDelete(directKeys);
  await disconnectConnections(connectionIds);
  await batchDelete(ownedPartitionKeys);
  await batchDelete(userKeys);

  try {
    await cognito.send(new AdminUserGlobalSignOutCommand({
      UserPoolId: cognitoUserPoolId,
      Username: username,
    }));
    await cognito.send(new AdminDeleteUserCommand({
      UserPoolId: cognitoUserPoolId,
      Username: username,
    }));
  } catch (error) {
    if (!(error instanceof Error) || error.name !== "UserNotFoundException") throw error;
  }
  return { statusCode: 204 };
}

async function deleteAccount(
  event: APIGatewayProxyEventV2,
): Promise<APIGatewayProxyStructuredResultV2> {
  const { sub: ownerSub, username } = recentAccountIdentity(event);
  if (!username) throw new Error("Account username claim is missing");
  return deleteAccountData(ownerSub, username);
}

async function recordAccountPasswordChanged(
  event: APIGatewayProxyEventV2,
): Promise<APIGatewayProxyStructuredResultV2> {
  if (!cognitoUserPoolId) throw new Error("Account security is not configured");
  const { sub: ownerSub, username } = recentAccountIdentity(event);
  if (!username) throw new Error("Account username claim is missing");
  await assertAccountActive(ownerSub);
  await cognito.send(new AdminUserGlobalSignOutCommand({
    UserPoolId: cognitoUserPoolId,
    Username: username,
  }));
  const credentialsChangedAt = nowSeconds();
  await dynamo.send(new UpdateCommand({
    TableName: tableName,
    Key: { PK: `USER#${ownerSub}`, SK: "ACCOUNT#META" },
    UpdateExpression: "SET credentialsChangedAt = :now",
    ConditionExpression: "attribute_exists(PK) AND username = :username",
    ExpressionAttributeValues: {
      ":now": credentialsChangedAt,
      ":username": username,
    },
  }));
  await revokeAccountControllers(ownerSub);
  return { statusCode: 204 };
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
  if (ownerSub) await assertAccountActive(ownerSub);
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
              lastSeenAt: registeredAt,
              status: "offline",
            },
            ConditionExpression: "attribute_not_exists(PK)",
          },
        }]
      : []),
    ...accountActiveCondition(ownerSub),
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
  await assertAccountActive(ownerSub);
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
              lastSeenAt: nowSeconds(),
              status: "offline",
            },
          },
        },
        ...accountActiveCondition(ownerSub),
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
  if (ownerSub) await assertAccountActive(ownerSub);
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
            },
              {
                Update: {
                  TableName: tableName,
                  Key: { PK: `USER#${ownerSub}`, SK: `DEVICE#${principalId}` },
                  UpdateExpression:
                    "SET #status = :connecting, lastSeenAt = :now, activeSessionId = :session, sessionStartedAt = :now, #name = :name",
                  ConditionExpression: "attribute_exists(PK)",
                  ExpressionAttributeNames: { "#status": "status", "#name": "name" },
                  ExpressionAttributeValues: {
                    ":connecting": "connecting",
                    ":now": createdAt,
                    ":session": sessionId,
                    ":name": deviceName,
                  },
                },
              },
            ]
          : []),
        ...accountActiveCondition(ownerSub),
      ],
    }),
  );
  return json(201, { sessionId, generation, accountOwned: Boolean(ownerSub) });
}

async function createPairing(
  event: APIGatewayProxyEventV2,
): Promise<APIGatewayProxyStructuredResultV2> {
  if (pairingDisabled) return json(503, { error: "New pairings are temporarily disabled" });
  const { principalId, principal } = await verifyAuthenticatedRequest(event);
  if (principal.deviceId !== principalId) return json(403, { error: "Only a registered Mac can create pairings" });
  const ownerSub = typeof principal.ownerSub === "string" ? principal.ownerSub : undefined;
  if (ownerSub) await assertAccountActive(ownerSub);
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
        ...accountActiveCondition(ownerSub),
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
  if (typeof session.Item.ownerSub === "string") await assertAccountActive(session.Item.ownerSub);
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
        ...accountActiveCondition(
          typeof session.Item.ownerSub === "string" ? session.Item.ownerSub : undefined,
        ),
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

async function accountRecords(
  ownerSub: string,
  prefix: "DEVICE#" | "SESSION#",
): Promise<Record<string, unknown>[]> {
  const items: Record<string, unknown>[] = [];
  let exclusiveStartKey: Record<string, unknown> | undefined;
  do {
    const result = await dynamo.send(
      new QueryCommand({
        TableName: tableName,
        KeyConditionExpression: "PK = :pk AND begins_with(SK, :prefix)",
        ExpressionAttributeValues: {
          ":pk": `USER#${ownerSub}`,
          ":prefix": prefix,
        },
        ConsistentRead: true,
        ...(exclusiveStartKey ? { ExclusiveStartKey: exclusiveStartKey } : {}),
      }),
    );
    items.push(...(result.Items ?? []));
    exclusiveStartKey = result.LastEvaluatedKey;
  } while (exclusiveStartKey);
  return items;
}

async function listAccountDevices(
  event: APIGatewayProxyEventV2,
): Promise<APIGatewayProxyStructuredResultV2> {
  const ownerSub = accountSubject(event);
  const [deviceItems, sessionItems] = await Promise.all([
    accountRecords(ownerSub, "DEVICE#"),
    accountRecords(ownerSub, "SESSION#"),
  ]);
  const now = nowSeconds();
  const activeSessions = new Map<string, Record<string, unknown>>();
  for (const session of sessionItems) {
    if (session.status !== "active" || Number(session.ttl) <= now) continue;
    const deviceId = String(session.deviceId ?? "");
    const previous = activeSessions.get(deviceId);
    if (!previous || Number(session.createdAt) > Number(previous.createdAt)) {
      activeSessions.set(deviceId, session);
    }
  }
  const devices = deviceItems.map((device) => {
    const deviceId = String(device.deviceId);
    const activeSession = activeSessions.get(deviceId);
    const recordedStatus = String(device.status ?? "legacy");
    const state = !activeSession || recordedStatus === "offline"
      ? "offline"
      : recordedStatus === "connecting"
        ? "connecting"
        : "online";
    return {
      deviceId,
      deviceName: String(device.name ?? "Mac"),
      registeredAt: Number(device.registeredAt ?? 0),
      lastSeenAt: Number(device.lastSeenAt ?? device.registeredAt ?? 0),
      state,
      ...(state === "online" && activeSession
        ? {
            sessionId: String(activeSession.sessionId),
            sessionCreatedAt: Number(activeSession.createdAt),
          }
        : {}),
    };
  }).sort((left, right) => {
    const rank: Record<string, number> = { online: 0, connecting: 1, offline: 2 };
    return (rank[left.state] ?? 3) - (rank[right.state] ?? 3) ||
      right.lastSeenAt - left.lastSeenAt ||
      left.deviceName.localeCompare(right.deviceName);
  });
  return json(200, { devices });
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
        ...accountActiveCondition(ownerSub),
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
  if (typeof session.Item.ownerSub === "string") await assertAccountActive(session.Item.ownerSub);

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
        ...accountActiveCondition(
          typeof session.Item.ownerSub === "string" ? session.Item.ownerSub : undefined,
        ),
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
    try {
      await dynamo.send(
        new UpdateCommand({
          TableName: tableName,
          Key: { PK: `USER#${principal.ownerSub}`, SK: `DEVICE#${principalId}` },
          UpdateExpression:
            "SET #status = :offline, lastSeenAt = :now REMOVE activeSessionId, activeConnectionId, sessionStartedAt",
          ConditionExpression:
            "attribute_not_exists(activeSessionId) OR activeSessionId = :session",
          ExpressionAttributeNames: { "#status": "status" },
          ExpressionAttributeValues: {
            ":offline": "offline",
            ":now": endedAt,
            ":session": sessionId,
          },
        }),
      );
    } catch {
      // A replacement session already owns the Mac's online indicator.
    }
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
  if (method === "POST" && path === "/api/v1/account-bootstrap") {
    return createAccountBootstrap(event);
  }
  if (method === "POST" && path === "/api/v1/account-bootstrap/status") {
    return accountBootstrapStatus(event);
  }
  if (method === "DELETE" && path === "/api/v1/account-bootstrap") {
    return cancelAccountBootstrap(event);
  }
  if (method === "POST" && path === "/api/v1/account-password-reset") {
    return createAccountPasswordReset(event);
  }
  if (method === "POST" && path === "/api/v1/account-password-reset/redeem") {
    return redeemAccountPasswordReset(event);
  }
  if (path.startsWith("/api/v1/account/") && !(method === "DELETE" && path === "/api/v1/account")) {
    const identity = accountIdentity(event);
    await assertAccountActive(identity.sub, identity.issuedAt);
  }
  if (method === "DELETE" && path === "/api/v1/account") {
    return deleteAccount(event);
  }
  if (method === "GET") {
    if (path === "/api/v1/account/sessions") return listAccountSessions(event);
    if (path === "/api/v1/account/devices") return listAccountDevices(event);
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
  if (path === "/api/v1/account/bootstrap/complete") {
    return completeAccountBootstrap(event);
  }
  if (path === "/api/v1/account/security/password-changed") {
    return recordAccountPasswordChanged(event);
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
    const message = error instanceof Error ? error.message : "Request failed";
    const statusCode =
      error instanceof SyntaxError || error instanceof TypeError
        ? 400
        : /auth|signature|principal|replay|stale|account has been deleted|credentials changed/iu.test(message)
          ? 401
          : 409;
    return json(statusCode, {
      error: message,
      ...(message === "Unknown or revoked principal"
        ? { code: "PRINCIPAL_REVOKED" }
        : {}),
    });
  }
};
