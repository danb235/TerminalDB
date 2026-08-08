import type { APIGatewayProxyEventV2, APIGatewayProxyStructuredResultV2 } from "aws-lambda";
import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => {
  process.env.PUBLIC_WEBSOCKET_URL = "wss://remote.example.invalid/socket";
  return {
    send: vi.fn(),
    verifyAuthenticatedRequest: vi.fn(),
  };
});

vi.mock("../lambdas/common.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../lambdas/common.js")>();
  return {
    ...actual,
    dynamo: { send: mocks.send },
    verifyAuthenticatedRequest: mocks.verifyAuthenticatedRequest,
  };
});

import { saltedHash, sha256 } from "../lambdas/common.js";
import { handler } from "../lambdas/control.js";

const tenantA = "11111111-1111-4111-8111-111111111111";
const tenantB = "22222222-2222-4222-8222-222222222222";
const activeUntil = Math.floor(Date.now() / 1_000) + 3_600;
const publicKey = { kty: "EC", crv: "P-256", x: "public-x", y: "public-y" };

function event(input: {
  readonly method: "GET" | "POST";
  readonly path: string;
  readonly body?: Record<string, unknown>;
  readonly sub?: string;
  readonly tokenUse?: "access" | "id";
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
                claims: { sub: input.sub, token_use: input.tokenUse ?? "access" },
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
    mocks.verifyAuthenticatedRequest.mockReset();
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
    expect(commandInput(mocks.send.mock.calls[0]?.[0]).ExpressionAttributeValues[":pk"])
      .toBe(`USER#${tenantA}`);
    expect(response.body).toContain("session-a");
  });

  it("does not reveal a different tenant's session during controller registration", async () => {
    mocks.send.mockResolvedValueOnce({
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
    expect(mocks.send).toHaveBeenCalledTimes(1);
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
    mocks.send.mockResolvedValue({
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
      path: "/api/v1/account/tickets",
      sub: tenantA,
      body: { sessionId: "session-b", role: "controller", clientId: "controller-b" },
    });

    expect(response.statusCode).toBe(403);
    expect(response.body).toContain("Cross-tenant ticket rejected");
    expect(mocks.send).toHaveBeenCalledTimes(1);
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

    const response = await invoke({
      method: "POST",
      path: "/api/v1/account/tickets",
      sub: tenantA,
      body: { sessionId: "session-a", role: "controller", clientId: "controller-a" },
    });

    expect(response.statusCode).toBe(401);
    expect(mocks.send).not.toHaveBeenCalled();
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
  });
});
