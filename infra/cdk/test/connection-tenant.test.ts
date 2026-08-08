import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ send: vi.fn() }));

vi.mock("../lambdas/common.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../lambdas/common.js")>();
  return { ...actual, dynamo: { send: mocks.send } };
});

import { handler } from "../lambdas/connection.js";

const tenantA = "11111111-1111-4111-8111-111111111111";
const tenantB = "22222222-2222-4222-8222-222222222222";
const activeUntil = Math.floor(Date.now() / 1_000) + 3_600;

function commandInput(command: unknown): Record<string, any> {
  return (command as { input: Record<string, any> }).input;
}

function connectEvent(input: {
  readonly clientId: string;
  readonly sessionId?: string;
  readonly ownerSub?: string;
}) {
  return {
    requestContext: {
      connectionId: "connection-1",
      eventType: "CONNECT",
      routeKey: "$connect",
      authorizer: {
        sessionId: input.sessionId ?? "session-a",
        role: "controller",
        clientId: input.clientId,
        generation: 1,
        ownerSub: input.ownerSub ?? "",
      },
    },
  };
}

describe("WebSocket connection tenant boundary", () => {
  beforeEach(() => mocks.send.mockReset());

  it("rejects an account controller whose ticket subject differs from the session", async () => {
    mocks.send
      .mockResolvedValueOnce({
        Item: {
          sessionId: "session-a",
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
          sessionId: "session-a",
          ownerSub: tenantB,
          accessMode: "account",
          ttl: activeUntil,
        },
      });

    const response = await handler(connectEvent({
      clientId: "controller-b",
      ownerSub: tenantA,
    }) as never);

    expect(response).toMatchObject({ statusCode: 403 });
    expect(mocks.send).toHaveBeenCalledTimes(2);
  });

  it("persists the verified account subject on matching connection records", async () => {
    mocks.send
      .mockResolvedValueOnce({
        Item: {
          sessionId: "session-a",
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
          sessionId: "session-a",
          ownerSub: tenantA,
          accessMode: "account",
          ttl: activeUntil,
        },
      })
      .mockResolvedValueOnce({});

    const response = await handler(connectEvent({
      clientId: "controller-a",
      ownerSub: tenantA,
    }) as never);

    expect(response).toMatchObject({ statusCode: 200 });
    const transaction = commandInput(mocks.send.mock.calls[2]?.[0]);
    expect(transaction.TransactItems[0].Put.Item.ownerSub).toBe(tenantA);
    expect(transaction.TransactItems[1].Put.Item.ownerSub).toBe(tenantA);
  });

  it("preserves the intentional guest-link exception on an account-owned session", async () => {
    mocks.send
      .mockResolvedValueOnce({
        Item: {
          sessionId: "session-a",
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
          sessionId: "session-a",
          accessMode: "pairing",
          ttl: activeUntil,
        },
      })
      .mockResolvedValueOnce({});

    const response = await handler(connectEvent({ clientId: "guest-controller" }) as never);

    expect(response).toMatchObject({ statusCode: 200 });
    const transaction = commandInput(mocks.send.mock.calls[2]?.[0]);
    expect(transaction.TransactItems[0].Put.Item.ownerSub).toBeUndefined();
  });

  it("atomically consumes a one-minute ticket and carries its tenant assertion", async () => {
    mocks.send.mockResolvedValue({
      Attributes: {
        clientId: "controller-a",
        sessionId: "session-a",
        role: "controller",
        generation: 1,
        ownerSub: tenantA,
        expiresAt: activeUntil,
      },
    });

    const response = await handler({
      type: "REQUEST",
      methodArn: "arn:aws:execute-api:region:account:api/stage/$connect",
      queryStringParameters: { ticket: "single-use-ticket" },
      requestContext: { connectionId: "pending" },
    } as never);

    expect(response).toMatchObject({
      principalId: "controller-a",
      policyDocument: {
        Statement: [{ Effect: "Allow" }],
      },
      context: { ownerSub: tenantA },
    });
    const deletion = commandInput(mocks.send.mock.calls[0]?.[0]);
    expect(deletion.ReturnValues).toBe("ALL_OLD");
    expect(deletion.Key.PK).toMatch(/^TICKET#/u);
  });
});
