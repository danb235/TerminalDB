import type {
  PostConfirmationTriggerEvent,
  PreSignUpTriggerEvent,
} from "aws-lambda";
import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => {
  process.env.TABLE_NAME = "account-table";
  return { send: vi.fn() };
});

vi.mock("../lambdas/common.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../lambdas/common.js")>();
  return { ...actual, dynamo: { send: mocks.send } };
});

import { sha256 } from "../lambdas/common.js";
import { handler } from "../lambdas/pre-signup.js";

const activeUntil = Math.floor(Date.now() / 1_000) + 3_600;
const bootstrapToken = "mac-approved-bootstrap-token-with-enough-entropy";

function signupEvent(input: {
  readonly clientId?: string;
  readonly token?: string;
  readonly username?: string;
} = {}): PreSignUpTriggerEvent {
  return {
    version: "1",
    region: "us-west-2",
    userPoolId: "us-west-2_pool",
    userName: input.username ?? "qa-user",
    callerContext: { awsSdkVersion: "3", clientId: input.clientId ?? "web-client" },
    triggerSource: "PreSignUp_SignUp",
    request: {
      userAttributes: {},
      validationData: {},
      clientMetadata: input.token === undefined
        ? { bootstrapToken }
        : input.token
          ? { bootstrapToken: input.token }
          : {},
    },
    response: {
      autoConfirmUser: false,
      autoVerifyEmail: false,
      autoVerifyPhone: false,
    },
  };
}

function confirmationEvent(): PostConfirmationTriggerEvent {
  return {
    version: "1",
    region: "us-west-2",
    userPoolId: "us-west-2_pool",
    userName: "qa-user",
    callerContext: { awsSdkVersion: "3", clientId: "web-client" },
    triggerSource: "PostConfirmation_ConfirmSignUp",
    request: {
      userAttributes: {},
      clientMetadata: { bootstrapToken },
    },
    response: {},
  };
}

function commandInput(command: unknown): Record<string, any> {
  return (command as { input: Record<string, any> }).input;
}

describe("TerminalDB Cognito signup", () => {
  beforeEach(() => {
    mocks.send.mockReset();
  });

  it("reserves a live Mac approval and auto-confirms the no-email user", async () => {
    mocks.send
      .mockResolvedValueOnce({ Item: {
        status: "pending",
        clientId: "web-client",
        ttl: activeUntil,
      } })
      .mockResolvedValueOnce({});

    const result = await handler(signupEvent());

    expect(result.response).toMatchObject({
      autoConfirmUser: true,
      autoVerifyEmail: false,
      autoVerifyPhone: false,
    });
    const reservation = commandInput(mocks.send.mock.calls[1]?.[0]);
    expect(reservation.Key).toEqual({
      PK: `ACCOUNT_BOOTSTRAP#${sha256(bootstrapToken)}`,
      SK: "META",
    });
    expect(reservation.ExpressionAttributeValues).toMatchObject({
      ":prepared": "signup-prepared",
      ":username": "qa-user",
    });
    expect(JSON.stringify(reservation)).not.toContain(bootstrapToken);
  });

  it("rejects hosted signup without a Mac approval before MFA setup", async () => {
    await expect(handler(signupEvent({ token: "" })))
      .rejects.toThrow("approved Mac");
    expect(mocks.send).not.toHaveBeenCalled();
  });

  it("rejects an expired, wrong-client, or replayed approval", async () => {
    for (const item of [
      { status: "pending", clientId: "web-client", ttl: activeUntil - 7_200 },
      { status: "pending", clientId: "other-client", ttl: activeUntil },
      { status: "signup-prepared", clientId: "web-client", ttl: activeUntil, cognitoUsername: "other-user" },
    ]) {
      mocks.send.mockReset();
      mocks.send.mockResolvedValueOnce({ Item: item });
      await expect(handler(signupEvent()))
        .rejects.toThrow("invalid or has expired");
    }
  });

  it("allows the same username to resume an interrupted prepared signup", async () => {
    mocks.send
      .mockResolvedValueOnce({ Item: {
        status: "signup-prepared",
        cognitoUsername: "qa-user",
        clientId: "web-client",
        ttl: activeUntil,
      } })
      .mockResolvedValueOnce({});

    await expect(handler(signupEvent())).resolves.toBeDefined();
    expect(commandInput(mocks.send.mock.calls[1]?.[0]).ConditionExpression)
      .toContain("cognitoUsername = :username");
  });

  it("marks a newly confirmed Cognito user safe for cancellation cleanup", async () => {
    mocks.send.mockResolvedValueOnce({});

    await expect(handler(confirmationEvent())).resolves.toBeDefined();

    const confirmation = commandInput(mocks.send.mock.calls[0]?.[0]);
    expect(confirmation.ExpressionAttributeValues).toMatchObject({
      ":prepared": "signup-prepared",
      ":confirmed": "signup-confirmed",
      ":username": "qa-user",
    });
  });

  it("rejects non-self-service trigger sources", async () => {
    const event = signupEvent();
    event.triggerSource = "PreSignUp_AdminCreateUser";
    await expect(handler(event)).rejects.toThrow("secure Cognito flow");
  });
});
