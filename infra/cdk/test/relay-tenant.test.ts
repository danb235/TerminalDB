import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ send: vi.fn(), post: vi.fn() }));

vi.mock("../lambdas/common.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../lambdas/common.js")>();
  return { ...actual, dynamo: { send: mocks.send } };
});

vi.mock("@aws-sdk/client-apigatewaymanagementapi", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@aws-sdk/client-apigatewaymanagementapi")>();
  return {
    ...actual,
    ApiGatewayManagementApiClient: class {
      send(command: unknown) {
        return mocks.post(command);
      }
    },
  };
});

import { handler } from "../lambdas/relay.js";

const tenantA = "11111111-1111-4111-8111-111111111111";
const tenantB = "22222222-2222-4222-8222-222222222222";
const sessionId = "session-aaaaaaaaaaaa";
const activeUntil = Math.floor(Date.now() / 1_000) + 3_600;

function envelope(input: {
  readonly sourceId: string;
  readonly destinationId?: string;
  readonly route?: "health.ping" | "account.bootstrap" | "account.bootstrap.ready";
}): string {
  const now = Date.now();
  return JSON.stringify({
    version: 1,
    route: input.route ?? "health.ping",
    sessionId,
    sourceId: input.sourceId,
    ...(input.destinationId ? { destinationId: input.destinationId } : {}),
    generation: 1,
    sequence: 1,
    requestId: "request-aaaaaaaaa",
    sentAt: now,
    expiresAt: now + 15_000,
    compression: "none",
    nonce: "nonce-aaaaaaaaaaa",
    ciphertext: "ciphertext",
  });
}

function relayEvent(body: string) {
  return {
    body,
    requestContext: {
      connectionId: "source-connection",
      domainName: "socket.example.invalid",
      stage: "dev",
    },
  };
}

describe("ciphertext relay tenant boundary", () => {
  beforeEach(() => {
    mocks.send.mockReset();
    mocks.post.mockReset();
    mocks.post.mockResolvedValue({});
  });

  it("rejects controller-to-Mac routing when account subjects differ", async () => {
    mocks.send
      .mockResolvedValueOnce({
        Item: {
          sessionId,
          role: "controller",
          clientId: "controller-b",
          generation: 1,
          ownerSub: tenantA,
        },
      })
      .mockResolvedValueOnce({
        Item: {
          sessionId,
          deviceId: "mac-a",
          ownerSub: tenantA,
          status: "active",
          generation: 1,
          ttl: activeUntil,
        },
      })
      .mockResolvedValueOnce({
        Item: {
          controllerId: "controller-b",
          sessionId,
          accessMode: "account",
          ownerSub: tenantB,
          ttl: activeUntil,
        },
      });

    const response = await handler(relayEvent(envelope({ sourceId: "controller-b" }))) as {
      statusCode: number;
    };

    expect(response.statusCode).toBe(403);
    expect(mocks.post).not.toHaveBeenCalled();
  });

  it("rejects Mac-to-controller routing to a controller from another tenant", async () => {
    mocks.send
      .mockResolvedValueOnce({
        Item: { sessionId, role: "mac", clientId: "mac-a", generation: 1 },
      })
      .mockResolvedValueOnce({
        Item: {
          sessionId,
          deviceId: "mac-a",
          ownerSub: tenantA,
          status: "active",
          generation: 1,
          ttl: activeUntil,
        },
      })
      .mockResolvedValueOnce({
        Item: {
          controllerId: "controller-b",
          sessionId,
          accessMode: "account",
          ownerSub: tenantB,
          ttl: activeUntil,
        },
      });

    const response = await handler(relayEvent(envelope({
      sourceId: "mac-a",
      destinationId: "controller-b",
    }))) as { statusCode: number };

    expect(response.statusCode).toBe(403);
    expect(mocks.post).not.toHaveBeenCalled();
  });

  it("routes a matching account controller without inspecting ciphertext", async () => {
    mocks.send
      .mockResolvedValueOnce({
        Item: {
          sessionId,
          role: "controller",
          clientId: "controller-a",
          generation: 1,
          ownerSub: tenantA,
        },
      })
      .mockResolvedValueOnce({
        Item: {
          sessionId,
          deviceId: "mac-a",
          ownerSub: tenantA,
          status: "active",
          generation: 1,
          ttl: activeUntil,
        },
      })
      .mockResolvedValueOnce({
        Item: {
          controllerId: "controller-a",
          sessionId,
          accessMode: "account",
          ownerSub: tenantA,
          ttl: activeUntil,
        },
      })
      .mockResolvedValueOnce({ Item: { connectionId: "mac-connection" } });

    const body = envelope({ sourceId: "controller-a" });
    const response = await handler(relayEvent(body)) as { statusCode: number };

    expect(response.statusCode).toBe(200);
    expect(mocks.post).toHaveBeenCalledTimes(1);
    const postInput = (mocks.post.mock.calls[0]?.[0] as { input: { Data: Uint8Array } }).input;
    expect(Buffer.from(postInput.Data).toString("utf8")).toBe(body);
  });

  it("preserves guest-link routing on an account-owned session", async () => {
    mocks.send
      .mockResolvedValueOnce({
        Item: {
          sessionId,
          role: "controller",
          clientId: "guest-controller",
          generation: 1,
        },
      })
      .mockResolvedValueOnce({
        Item: {
          sessionId,
          deviceId: "mac-a",
          ownerSub: tenantA,
          status: "active",
          generation: 1,
          ttl: activeUntil,
        },
      })
      .mockResolvedValueOnce({
        Item: {
          controllerId: "guest-controller",
          sessionId,
          accessMode: "pairing",
          ttl: activeUntil,
        },
      })
      .mockResolvedValueOnce({ Item: { connectionId: "mac-connection" } });

    const response = await handler(relayEvent(envelope({
      sourceId: "guest-controller",
      route: "account.bootstrap",
    }))) as {
      statusCode: number;
    };

    expect(response.statusCode).toBe(200);
    expect(mocks.post).toHaveBeenCalledTimes(1);
  });

  it("relays the Mac's encrypted account approval back to the guest controller", async () => {
    mocks.send
      .mockResolvedValueOnce({
        Item: { sessionId, role: "mac", clientId: "mac-a", generation: 1 },
      })
      .mockResolvedValueOnce({
        Item: {
          sessionId,
          deviceId: "mac-a",
          ownerSub: tenantA,
          status: "active",
          generation: 1,
          ttl: activeUntil,
        },
      })
      .mockResolvedValueOnce({
        Item: {
          controllerId: "guest-controller",
          sessionId,
          accessMode: "pairing",
          ttl: activeUntil,
        },
      })
      .mockResolvedValueOnce({ Item: { connectionId: "controller-connection" } });

    const response = await handler(relayEvent(envelope({
      sourceId: "mac-a",
      destinationId: "guest-controller",
      route: "account.bootstrap.ready",
    }))) as { statusCode: number };

    expect(response.statusCode).toBe(200);
    expect(mocks.post).toHaveBeenCalledTimes(1);
  });
});
