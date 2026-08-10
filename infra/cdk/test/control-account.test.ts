import type { APIGatewayProxyEventV2, APIGatewayProxyStructuredResultV2 } from "aws-lambda";
import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => {
  process.env.PUBLIC_WEBSOCKET_URL = "wss://remote.example.invalid/socket";
  process.env.COGNITO_USER_POOL_ID = "us-west-2_testpool";
  process.env.COGNITO_CLIENT_ID = "web-client";
  return {
    send: vi.fn(),
    cognitoSend: vi.fn(),
    verifyAuthenticatedRequest: vi.fn(),
    verifyP256Signature: vi.fn(),
  };
});

vi.mock("@aws-sdk/client-cognito-identity-provider", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@aws-sdk/client-cognito-identity-provider")>();
  return {
    ...actual,
    CognitoIdentityProviderClient: class {
      send(command: unknown) {
        return mocks.cognitoSend(command);
      }
    },
  };
});

vi.mock("../lambdas/common.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../lambdas/common.js")>();
  return {
    ...actual,
    dynamo: { send: mocks.send },
    verifyAuthenticatedRequest: mocks.verifyAuthenticatedRequest,
    verifyP256Signature: mocks.verifyP256Signature,
  };
});

import { saltedHash, sha256 } from "../lambdas/common.js";
import { handler } from "../lambdas/control.js";

const tenantA = "11111111-1111-4111-8111-111111111111";
const tenantB = "22222222-2222-4222-8222-222222222222";
const activeUntil = Math.floor(Date.now() / 1_000) + 3_600;
const publicKey = { kty: "EC", crv: "P-256", x: "public-x", y: "public-y" };

function event(input: {
  readonly method: "DELETE" | "GET" | "POST";
  readonly path: string;
  readonly body?: Record<string, unknown>;
  readonly sub?: string;
  readonly tokenUse?: "access" | "id";
  readonly issuedAt?: number;
}): APIGatewayProxyEventV2 {
  return {
    version: "2.0",
    routeKey: "$default",
    rawPath: input.path,
    rawQueryString: "",
    headers: {},
    requestContext: {
      accountId: "111111111111",
      apiId: "api",
      domainName: "remote.example.invalid",
      domainPrefix: "remote",
      http: {
        method: input.method,
        path: input.path,
        protocol: "HTTP/1.1",
        sourceIp: "127.0.0.1",
        userAgent: "qa",
      },
      requestId: "request",
      routeKey: "$default",
      stage: "$default",
      time: "",
      timeEpoch: Date.now(),
      ...(input.sub
        ? {
            authorizer: {
              jwt: {
                claims: {
                  sub: input.sub,
                  token_use: input.tokenUse ?? "access",
                  username: "qa-user",
                  ...(input.issuedAt ? { iat: input.issuedAt } : {}),
                },
                scopes: ["openid"],
              },
            },
          }
        : {}),
    },
    ...(input.body ? { body: JSON.stringify(input.body) } : {}),
    isBase64Encoded: false,
  } as unknown as APIGatewayProxyEventV2;
}

async function invoke(input: Parameters<typeof event>[0]): Promise<APIGatewayProxyStructuredResultV2> {
  return await handler(event(input), {} as never, () => undefined) as APIGatewayProxyStructuredResultV2;
}

function commandInput(command: unknown): Record<string, any> {
  return (command as { input: Record<string, any> }).input;
}

describe("account control-plane tenant isolation", () => {
  beforeEach(() => {
    mocks.send.mockReset();
    mocks.cognitoSend.mockReset();
    mocks.cognitoSend.mockResolvedValue({});
    mocks.verifyAuthenticatedRequest.mockReset();
    mocks.verifyP256Signature.mockReset();
    mocks.verifyP256Signature.mockReturnValue(true);
  });

  it("mints a rate-limited one-time signup grant only after a Mac key proof", async () => {
    mocks.send.mockResolvedValue({});
    const response = await invoke({
      method: "POST",
      path: "/api/v1/account-bootstrap",
      body: {
        timestamp: Date.now(),
        nonce: "bootstrap-nonce",
        deviceName: "QA Mac",
        signingPublicKey: publicKey,
        agreementPublicKey: publicKey,
        signature: "mac-signature",
      },
    });

    expect(response.statusCode).toBe(201);
    expect(mocks.verifyP256Signature).toHaveBeenCalledTimes(1);
    const responseBody = JSON.parse(response.body ?? "{}") as { bootstrapToken: string };
    expect(responseBody.bootstrapToken).toMatch(/^[\w-]{40,}$/u);
    const transaction = commandInput(mocks.send.mock.calls[0]?.[0]);
    const records = transaction.TransactItems.map((item: any) => item.Put?.Item);
    expect(records).toEqual(expect.arrayContaining([
      expect.objectContaining({ PK: expect.stringMatching(/^ACCOUNT_BOOTSTRAP#/u), status: "pending" }),
      expect.objectContaining({ PK: expect.stringMatching(/^BOOTSTRAP_RATE#/u) }),
      expect.objectContaining({ PK: expect.stringMatching(/^BOOTSTRAP_NONCE#/u) }),
    ]));
    expect(JSON.stringify(transaction)).not.toContain(responseBody.bootstrapToken);
  });

  it("lets the holder of an unused one-time grant cancel account setup", async () => {
    mocks.send.mockImplementation(async (command: unknown) => {
      const input = commandInput(command);
      return input.ReturnValues === "ALL_OLD"
        ? { Attributes: { status: "pending", ttl: activeUntil } }
        : {};
    });

    const response = await invoke({
      method: "DELETE",
      path: "/api/v1/account-bootstrap",
      body: { bootstrapToken: "cancel-this-bootstrap" },
    });

    expect(response.statusCode).toBe(200);
    expect(JSON.parse(response.body ?? "{}")).toEqual({ canceled: true });
    const deletion = mocks.send.mock.calls
      .map(([command]) => commandInput(command))
      .find((input) => input.ConditionExpression);
    expect(deletion).toBeDefined();
    expect(deletion!.Key.PK).toBe(`ACCOUNT_BOOTSTRAP#${sha256("cancel-this-bootstrap")}`);
    expect(deletion!.ConditionExpression).toContain("#status <> :complete");
    expect(JSON.stringify(deletion)).not.toContain("cancel-this-bootstrap");
  });

  it("removes an incomplete legacy Cognito user when its signup is canceled", async () => {
    mocks.send.mockImplementation(async (command: unknown) => {
      const input = commandInput(command);
      return input.ReturnValues === "ALL_OLD"
        ? {
            Attributes: {
              status: "signup-confirmed",
              cognitoUsername: "unfinished-user",
              ttl: activeUntil,
            },
          }
        : {};
    });

    const response = await invoke({
      method: "DELETE",
      path: "/api/v1/account-bootstrap",
      body: { bootstrapToken: "legacy-bootstrap" },
    });

    expect(response.statusCode).toBe(200);
    const cognitoRequest = commandInput(mocks.cognitoSend.mock.calls[0]?.[0]);
    expect(cognitoRequest).toEqual({
      UserPoolId: "us-west-2_testpool",
      Username: "unfinished-user",
    });
  });

  it("never deletes a Cognito user after account completion wins the cancellation race", async () => {
    mocks.send.mockImplementation(async (command: unknown) => {
      const input = commandInput(command);
      if (input.ReturnValues === "ALL_OLD") {
        throw Object.assign(new Error("completion won"), {
          name: "ConditionalCheckFailedException",
        });
      }
      return input.ConsistentRead
        ? { Item: { status: "complete", ttl: activeUntil } }
        : {};
    });

    const response = await invoke({
      method: "DELETE",
      path: "/api/v1/account-bootstrap",
      body: { bootstrapToken: "completed-bootstrap" },
    });

    expect(response.statusCode).toBe(409);
    expect(mocks.cognitoSend).not.toHaveBeenCalled();
  });

  it("atomically binds the approved Cognito subject to the waiting Mac", async () => {
    mocks.send.mockImplementation(async (command: unknown) => {
      const input = commandInput(command);
      if (input.Key?.SK === "ACCOUNT#DELETED") return {};
      if (String(input.Key?.PK).startsWith("ACCOUNT_BOOTSTRAP#")) {
        return {
          Item: {
            PK: input.Key.PK,
            SK: "META",
            status: "signup-confirmed",
            cognitoUsername: "qa-user",
            deviceName: "QA Mac",
            signingPublicKey: publicKey,
            agreementPublicKey: publicKey,
            previousDeviceId: "existing-guest-mac",
            ttl: activeUntil,
          },
        };
      }
      return {};
    });

    const response = await invoke({
      method: "POST",
      path: "/api/v1/account/bootstrap/complete",
      sub: tenantA,
      body: { bootstrapToken: "approved-bootstrap" },
    });

    expect(response.statusCode).toBe(200);
    const transaction = mocks.send.mock.calls
      .map(([command]) => commandInput(command))
      .find((input) => input.TransactItems);
    const serialized = JSON.stringify(transaction);
    expect(serialized).toContain(`USER#${tenantA}`);
    expect(serialized).toContain('"recovery":"authenticator-app-only"');
    expect(serialized).toContain('":owner":"11111111-1111-4111-8111-111111111111"');
    expect(serialized).toContain('"#temporary":"temporary"');
    expect(serialized).toContain("REMOVE #ttl, #temporary");
    expect(serialized).not.toContain("approved-bootstrap");
  });

  it("creates the TerminalDB account after Cognito managed signup and binds the waiting Mac", async () => {
    mocks.send.mockImplementation(async (command: unknown) => {
      const input = commandInput(command);
      if (String(input.Key?.PK).startsWith("ACCOUNT_BOOTSTRAP#")) {
        return {
          Item: {
            PK: input.Key.PK,
            SK: "META",
            status: "pending",
            deviceName: "QA Mac",
            signingPublicKey: publicKey,
            agreementPublicKey: publicKey,
            ttl: activeUntil,
          },
        };
      }
      return {};
    });

    const response = await invoke({
      method: "POST",
      path: "/api/v1/account/bootstrap/complete",
      sub: tenantA,
      issuedAt: Math.floor(Date.now() / 1_000),
      body: { bootstrapToken: "managed-login-bootstrap" },
    });

    expect(response.statusCode).toBe(200);
    const transaction = mocks.send.mock.calls
      .map(([command]) => commandInput(command))
      .find((input) => input.TransactItems);
    const serialized = JSON.stringify(transaction);
    expect(serialized).toContain('"#status = :pending AND #ttl > :now"');
    expect(serialized).toContain(`"PK":"USER#${tenantA}","SK":"ACCOUNT#META"`);
    expect(serialized).toContain('"recovery":"authenticator-app-only"');
  });

  it("connects another Mac only after a fresh login to an existing account", async () => {
    mocks.send.mockImplementation(async (command: unknown) => {
      const input = commandInput(command);
      if (String(input.Key?.PK).startsWith("ACCOUNT_BOOTSTRAP#")) {
        return {
          Item: {
            status: "pending",
            deviceName: "Second Mac",
            signingPublicKey: publicKey,
            agreementPublicKey: publicKey,
            ttl: activeUntil,
          },
        };
      }
      if (input.Key?.SK === "ACCOUNT#META") {
        return { Item: { username: "qa-user", createdAt: activeUntil - 3_600 } };
      }
      return {};
    });

    const response = await invoke({
      method: "POST",
      path: "/api/v1/account/bootstrap/complete",
      sub: tenantA,
      issuedAt: Math.floor(Date.now() / 1_000),
      body: { bootstrapToken: "existing-account-bootstrap" },
    });

    expect(response.statusCode).toBe(200);
    const transaction = mocks.send.mock.calls
      .map(([command]) => commandInput(command))
      .find((input) => input.TransactItems);
    expect(transaction).toBeDefined();
    expect(transaction!.TransactItems).toEqual(expect.arrayContaining([
      expect.objectContaining({
        ConditionCheck: expect.objectContaining({
          Key: { PK: `USER#${tenantA}`, SK: "ACCOUNT#META" },
        }),
      }),
    ]));
    const bootstrapUpdate = transaction!.TransactItems.find(
      (item: {
        Update?: {
          Key?: { PK?: unknown; SK?: unknown };
          ConditionExpression?: string;
          ExpressionAttributeValues?: Record<string, unknown>;
        };
      }) => item.Update?.Key?.SK === "META" &&
        String(item.Update?.Key?.PK).startsWith("ACCOUNT_BOOTSTRAP#"),
    )?.Update;
    expect(bootstrapUpdate?.ConditionExpression).toContain(":pending");
    expect(bootstrapUpdate?.ExpressionAttributeValues?.[":pending"]).toBe("pending");
    expect(JSON.stringify(transaction)).not.toContain('"recovery"');
  });

  it("finalizes a browser-side Cognito password change only after recent MFA login", async () => {
    mocks.send.mockResolvedValue({});

    const response = await invoke({
      method: "POST",
      path: "/api/v1/account/security/password-changed",
      sub: tenantA,
      issuedAt: Math.floor(Date.now() / 1_000),
    });

    expect(response.statusCode).toBe(204);
    expect(mocks.cognitoSend).toHaveBeenCalledTimes(1);
    expect(mocks.cognitoSend.mock.calls[0]?.[0].constructor.name)
      .toBe("AdminUserGlobalSignOutCommand");
    const credentialUpdate = mocks.send.mock.calls
      .map(([command]) => commandInput(command))
      .find((input) => String(input.UpdateExpression).includes("credentialsChangedAt"));
    expect(credentialUpdate).toMatchObject({
      Key: { PK: `USER#${tenantA}`, SK: "ACCOUNT#META" },
      ConditionExpression: "attribute_exists(PK) AND username = :username",
    });
  });

  it("rejects stale tokens for account security actions", async () => {
    mocks.send.mockResolvedValue({});
    const response = await invoke({
      method: "POST",
      path: "/api/v1/account/security/password-changed",
      sub: tenantA,
      issuedAt: Math.floor(Date.now() / 1_000) - 10 * 60,
    });

    expect(response.statusCode).toBe(401);
    expect(JSON.parse(response.body ?? "{}").error).toBe(
      "Recent account authentication required",
    );
    expect(mocks.cognitoSend).not.toHaveBeenCalled();
  });

  it("returns a stable revocation code when a deleted account Mac reconnects", async () => {
    mocks.verifyAuthenticatedRequest.mockRejectedValue(
      new Error("Unknown or revoked principal"),
    );

    const response = await invoke({
      method: "POST",
      path: "/api/v1/sessions",
      body: { protocolVersion: 1 },
    });

    expect(response.statusCode).toBe(401);
    expect(JSON.parse(response.body ?? "{}")).toEqual({
      error: "Unknown or revoked principal",
      code: "PRINCIPAL_REVOKED",
    });
  });

  it("rejects account API tokens issued at or before a password change", async () => {
    mocks.send.mockImplementation(async (command: unknown) => {
      const input = commandInput(command);
      if (input.Key?.SK === "ACCOUNT#DELETED") return {};
      if (input.Key?.SK === "ACCOUNT#META") {
        return { Item: { username: "qa-user", credentialsChangedAt: 200 } };
      }
      return { Items: [] };
    });

    const response = await invoke({
      method: "GET",
      path: "/api/v1/account/sessions",
      sub: tenantA,
      issuedAt: 200,
    });

    expect(response.statusCode).toBe(401);
    expect(response.body).toContain("Account credentials changed. Sign in again.");
  });

  it("queries sessions only under the verified JWT subject", async () => {
    mocks.send.mockResolvedValue({
      Items: [{
        sessionId: "session-a",
        deviceId: "mac-a",
        deviceName: "Mac A",
        status: "active",
        generation: 1,
        createdAt: 1_700_000_000,
        ttl: activeUntil,
      }],
    });

    const response = await invoke({
      method: "GET",
      path: "/api/v1/account/sessions",
      sub: tenantA,
    });

    expect(response.statusCode).toBe(200);
    const query = mocks.send.mock.calls
      .map(([command]) => commandInput(command))
      .find((input) => input.KeyConditionExpression);
    expect(query?.ExpressionAttributeValues[":pk"])
      .toBe(`USER#${tenantA}`);
    expect(response.body).toContain("session-a");
  });

  it("keeps every enrolled Mac visible and distinguishes online, connecting, and offline", async () => {
    mocks.send.mockImplementation(async (command: unknown) => {
      const input = commandInput(command);
      if (input.Key?.SK === "ACCOUNT#DELETED") return {};
      if (input.ExpressionAttributeValues?.[":prefix"] === "DEVICE#") {
        return {
          Items: [
            {
              deviceId: "mac-offline",
              name: "Office iMac",
              registeredAt: 1_700_000_000,
              lastSeenAt: 1_700_000_500,
              status: "offline",
            },
            {
              deviceId: "mac-online",
              name: "MacBook Pro",
              registeredAt: 1_700_000_100,
              lastSeenAt: 1_700_000_600,
              status: "online",
            },
            {
              deviceId: "mac-connecting",
              name: "Mac Studio",
              registeredAt: 1_700_000_200,
              lastSeenAt: 1_700_000_700,
              status: "connecting",
            },
          ],
        };
      }
      if (input.ExpressionAttributeValues?.[":prefix"] === "SESSION#") {
        return {
          Items: [
            {
              sessionId: "session-online",
              deviceId: "mac-online",
              status: "active",
              createdAt: 1_700_000_800,
              ttl: activeUntil,
            },
            {
              sessionId: "session-connecting",
              deviceId: "mac-connecting",
              status: "active",
              createdAt: 1_700_000_900,
              ttl: activeUntil,
            },
            {
              sessionId: "stale-session",
              deviceId: "mac-offline",
              status: "active",
              createdAt: 1_700_001_000,
              ttl: activeUntil,
            },
          ],
        };
      }
      return {};
    });

    const response = await invoke({
      method: "GET",
      path: "/api/v1/account/devices",
      sub: tenantA,
    });

    expect(response.statusCode).toBe(200);
    const body = JSON.parse(response.body ?? "{}") as {
      devices: Array<Record<string, unknown>>;
    };
    expect(body.devices).toEqual([
      expect.objectContaining({
        deviceId: "mac-online",
        state: "online",
        sessionId: "session-online",
      }),
      expect.objectContaining({
        deviceId: "mac-connecting",
        state: "connecting",
      }),
      expect.objectContaining({
        deviceId: "mac-offline",
        state: "offline",
      }),
    ]);
    expect(body.devices[1]).not.toHaveProperty("sessionId");
    expect(body.devices[2]).not.toHaveProperty("sessionId");
    const accountQueries = mocks.send.mock.calls
      .map(([command]) => commandInput(command))
      .filter((input) => input.KeyConditionExpression);
    expect(accountQueries).toHaveLength(2);
    expect(accountQueries.every((input) =>
      input.ExpressionAttributeValues[":pk"] === `USER#${tenantA}`)).toBe(true);
  });

  it("does not reveal a different tenant's session during controller registration", async () => {
    mocks.send.mockResolvedValueOnce({}).mockResolvedValueOnce({
      Item: {
        sessionId: "session-b",
        deviceId: "mac-b",
        ownerSub: tenantB,
        status: "active",
        ttl: activeUntil,
      },
    });

    const response = await invoke({
      method: "POST",
      path: "/api/v1/account/sessions/session-b/controllers",
      sub: tenantA,
      body: {
        browserId: "browser-a",
        protocolVersion: 1,
        deviceName: "Browser A",
        signingPublicKey: publicKey,
        agreementPublicKey: publicKey,
      },
    });

    expect(response.statusCode).toBe(404);
    expect(response.body).toContain("Active session not found");
    expect(mocks.send).toHaveBeenCalledTimes(2);
  });

  it("writes controller ownership from the token and ignores body tenant fields", async () => {
    mocks.send.mockImplementation(async (command: unknown) => {
      const input = commandInput(command);
      if (input.Key?.PK === "SESSION#session-a") {
        return {
          Item: {
            sessionId: "session-a",
            deviceId: "mac-a",
            ownerSub: tenantA,
            status: "active",
            generation: 1,
            controllerCount: 4,
            agreementPublicKey: publicKey,
            ttl: activeUntil,
          },
        };
      }
      if (input.Key?.PK === `USER#${tenantA}`) return {};
      if (input.Select === "COUNT") return { Count: 0 };
      return {};
    });

    const response = await invoke({
      method: "POST",
      path: "/api/v1/account/sessions/session-a/controllers",
      sub: tenantA,
      body: {
        ownerSub: tenantB,
        tenantId: tenantB,
        browserId: "browser-a",
        protocolVersion: 1,
        deviceName: "Browser A",
        signingPublicKey: publicKey,
        agreementPublicKey: publicKey,
      },
    });

    expect(response.statusCode).toBe(201);
    const transaction = mocks.send.mock.calls
      .map(([command]) => commandInput(command))
      .find((input) => input.TransactItems);
    const controller = transaction?.TransactItems[0].Put.Item;
    expect(controller.ownerSub).toBe(tenantA);
    expect(controller.ownerSub).not.toBe(tenantB);
    const capacityUpdate = transaction?.TransactItems[3].Update;
    expect(capacityUpdate.ExpressionAttributeValues[":observed"]).toBe(4);
    expect(capacityUpdate.ExpressionAttributeValues[":next"]).toBe(1);
    expect(transaction?.TransactItems[4].ConditionCheck).toMatchObject({
      Key: { PK: `USER#${tenantA}`, SK: "ACCOUNT#DELETED" },
      ConditionExpression: "attribute_not_exists(PK)",
    });
  });

  it("rejects an account ticket when token, controller, and session subjects differ", async () => {
    mocks.verifyAuthenticatedRequest.mockResolvedValue({
      principalId: "controller-b",
      principal: {
        controllerId: "controller-b",
        sessionId: "session-b",
        deviceId: "mac-b",
        accessMode: "account",
        ownerSub: tenantB,
      },
    });
    mocks.send.mockImplementation(async (command: unknown) => {
      const input = commandInput(command);
      if (input.Key?.PK === `USER#${tenantA}`) return {};
      return {
        Item: {
          sessionId: "session-b",
          deviceId: "mac-b",
          ownerSub: tenantB,
          status: "active",
          ttl: activeUntil,
        },
      };
    });

    const response = await invoke({
      method: "POST",
      path: "/api/v1/account/tickets",
      sub: tenantA,
      body: { sessionId: "session-b", role: "controller", clientId: "controller-b" },
    });

    expect(response.statusCode).toBe(403);
    expect(response.body).toContain("Cross-tenant ticket rejected");
    expect(mocks.send).toHaveBeenCalledTimes(2);
  });

  it("keeps the guest ticket route available without a Cognito subject", async () => {
    mocks.verifyAuthenticatedRequest.mockResolvedValue({
      principalId: "guest-controller",
      principal: {
        controllerId: "guest-controller",
        sessionId: "guest-session",
        deviceId: "mac-a",
        accessMode: "pairing",
      },
    });
    mocks.send.mockImplementation(async (command: unknown) => {
      const input = commandInput(command);
      if (input.Key?.PK === "SESSION#guest-session") {
        return {
          Item: {
            sessionId: "guest-session",
            deviceId: "mac-a",
            status: "active",
            generation: 1,
            ttl: activeUntil,
          },
        };
      }
      return {};
    });

    const response = await invoke({
      method: "POST",
      path: "/api/v1/tickets",
      body: { sessionId: "guest-session", role: "controller", clientId: "guest-controller" },
    });

    expect(response.statusCode).toBe(201);
    expect(response.body).toContain("wss://remote.example.invalid/socket");
  });

  it("requires an API-Gateway-verified access token on account routes", async () => {
    const response = await invoke({ method: "GET", path: "/api/v1/account/sessions" });

    expect(response.statusCode).toBe(401);
    expect(mocks.send).not.toHaveBeenCalled();
  });

  it("rejects an ID token even when its subject is otherwise valid", async () => {
    const response = await invoke({
      method: "GET",
      path: "/api/v1/account/sessions",
      sub: tenantA,
      tokenUse: "id",
    });

    expect(response.statusCode).toBe(401);
    expect(mocks.send).not.toHaveBeenCalled();
  });

  it("requires the registered controller signature in addition to the account JWT", async () => {
    mocks.verifyAuthenticatedRequest.mockRejectedValue(new Error("Invalid request signature"));
    mocks.send.mockResolvedValue({});

    const response = await invoke({
      method: "POST",
      path: "/api/v1/account/tickets",
      sub: tenantA,
      body: { sessionId: "session-a", role: "controller", clientId: "controller-a" },
    });

    expect(response.statusCode).toBe(401);
    expect(mocks.send).toHaveBeenCalledTimes(1);
  });

  it("rejects an expired account enrollment before mutating the device", async () => {
    const code = "expired-account-enrollment";
    const salt = "salt";
    mocks.verifyAuthenticatedRequest.mockResolvedValue({
      principalId: "mac-a",
      principal: { deviceId: "mac-a" },
    });
    mocks.send.mockResolvedValue({
      Item: {
        PK: `ENROLLMENT#${sha256(code)}`,
        SK: "META",
        ownerSub: tenantA,
        salt,
        secretHash: saltedHash(salt, code),
        expiresAt: Math.floor(Date.now() / 1_000) - 1,
      },
    });

    const response = await invoke({
      method: "POST",
      path: "/api/v1/devices/claim",
      body: { code },
    });

    expect(response.statusCode).toBe(401);
    expect(mocks.send).toHaveBeenCalledTimes(1);
  });

  it("atomically consumes an account enrollment while binding an existing Mac", async () => {
    const code = "account-enrollment-code";
    const salt = "salt";
    mocks.verifyAuthenticatedRequest.mockResolvedValue({
      principalId: "mac-a",
      principal: {
        deviceId: "mac-a",
        name: "Mac A",
        registeredAt: 1_700_000_000,
      },
    });
    mocks.send.mockImplementation(async (command: unknown) => {
      const input = commandInput(command);
      if (input.Key?.PK === `ENROLLMENT#${sha256(code)}`) {
        return {
          Item: {
            PK: `ENROLLMENT#${sha256(code)}`,
            SK: "META",
            enrollmentId: "enrollment-a",
            ownerSub: tenantA,
            salt,
            secretHash: saltedHash(salt, code),
            expiresAt: activeUntil,
          },
        };
      }
      return {};
    });

    const response = await invoke({
      method: "POST",
      path: "/api/v1/devices/claim",
      body: { code },
    });

    expect(response.statusCode).toBe(200);
    expect(response.body).toContain('"claimed":true');
    const transaction = mocks.send.mock.calls
      .map(([command]) => commandInput(command))
      .find((input) => input.TransactItems);
    expect(transaction).toBeDefined();
    expect(transaction!.TransactItems[0].Delete.Key.PK).toBe(`ENROLLMENT#${sha256(code)}`);
    expect(transaction!.TransactItems[2].Update.ExpressionAttributeValues[":owner"])
      .toBe(tenantA);
    expect(transaction!.TransactItems[2].Update.ConditionExpression)
      .toContain("attribute_not_exists(ownerSub) OR ownerSub = :owner");
    expect(transaction!.TransactItems[4].ConditionCheck.Key)
      .toEqual({ PK: `USER#${tenantA}`, SK: "ACCOUNT#DELETED" });
  });

  it("blocks an already-issued token after account deletion starts", async () => {
    mocks.send.mockResolvedValue({ Item: { deletedAt: 1_700_000_000 } });

    const response = await invoke({
      method: "GET",
      path: "/api/v1/account/sessions",
      sub: tenantA,
    });

    expect(response.statusCode).toBe(401);
    expect(response.body).toContain("Account has been deleted");
    expect(mocks.send).toHaveBeenCalledTimes(1);
  });

  it("deletes only the authenticated tenant and its owned remote records", async () => {
    mocks.send.mockImplementation(async (command: unknown) => {
      const input = commandInput(command);
      if (input.UpdateExpression?.includes("deletedAt")) return {};
      if (input.ExpressionAttributeValues?.[":pk"] === `USER#${tenantA}`) {
        return {
          Items: [
            { PK: `USER#${tenantA}`, SK: "ACCOUNT#DELETED", deletedAt: 1_700_000_000 },
            { PK: `USER#${tenantA}`, SK: "SESSION#session-a", sessionId: "session-a" },
            { PK: `USER#${tenantA}`, SK: "DEVICE#mac-a", deviceId: "mac-a" },
            {
              PK: `USER#${tenantA}`,
              SK: "CONTROLLER#session-a#browser-a",
              sessionId: "session-a",
              controllerId: "controller-a",
            },
            {
              PK: `USER#${tenantA}`,
              SK: "ENROLLMENT#enrollment-a",
              codeHash: "enrollment-hash-a",
            },
          ],
        };
      }
      if (input.ExpressionAttributeValues?.[":pk"] === "SESSION#session-a") {
        return {
          Items: [
            { PK: "SESSION#session-a", SK: "META", sessionId: "session-a" },
            {
              PK: "SESSION#session-a",
              SK: "CONTROLLER#controller-a",
              controllerId: "controller-a",
            },
            {
              PK: "SESSION#session-a",
              SK: "SOCKET#controller#controller-a",
              connectionId: "connection-a",
            },
            { PK: "SESSION#session-a", SK: "PAIRING#pairing-a", pairingId: "pairing-a" },
          ],
        };
      }
      if (input.ExpressionAttributeValues?.[":pk"] === "DEVICE#mac-a") {
        return {
          Items: [
            { PK: "DEVICE#mac-a", SK: "META", deviceId: "mac-a" },
            { PK: "DEVICE#mac-a", SK: "SESSION#session-a", sessionId: "session-a" },
          ],
        };
      }
      return {};
    });

    const response = await invoke({
      method: "DELETE",
      path: "/api/v1/account",
      sub: tenantA,
      issuedAt: Math.floor(Date.now() / 1_000),
    });

    expect(response.statusCode).toBe(204);
    const batches = mocks.send.mock.calls
      .map(([command]) => commandInput(command))
      .filter((input) => input.RequestItems);
    const deleteRequests = batches.flatMap((batch) =>
      Object.values(batch.RequestItems).flat(),
    ) as Array<{ DeleteRequest: { Key: Record<string, string> } }>;
    const deletedKeys = deleteRequests.map((item) => item.DeleteRequest.Key);
    expect(deletedKeys).toContainEqual({ PK: "SESSION#session-a", SK: "META" });
    expect(deletedKeys).toContainEqual({ PK: "DEVICE#mac-a", SK: "META" });
    expect(deletedKeys).toContainEqual({ PK: "CONTROLLER#controller-a", SK: "META" });
    expect(deletedKeys).toContainEqual({ PK: "PAIRING#pairing-a", SK: "META" });
    expect(deletedKeys).toContainEqual({ PK: "ENROLLMENT#enrollment-hash-a", SK: "META" });
    expect(deletedKeys).not.toContainEqual({ PK: `USER#${tenantA}`, SK: "ACCOUNT#DELETED" });
    expect(JSON.stringify(deletedKeys)).not.toContain(tenantB);
    expect(mocks.cognitoSend).toHaveBeenCalledTimes(2);
  });
});
