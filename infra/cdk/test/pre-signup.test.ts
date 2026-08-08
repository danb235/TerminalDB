import type { PreSignUpTriggerEvent } from "aws-lambda";
import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ send: vi.fn() }));

vi.mock("../lambdas/common.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../lambdas/common.js")>();
  return { ...actual, dynamo: { send: mocks.send }, tableName: "RemoteState" };
});

import { sha256 } from "../lambdas/common.js";
import { handler } from "../lambdas/pre-signup.js";

function signupEvent(token?: string): PreSignUpTriggerEvent {
  return {
    version: "1",
    region: "us-west-2",
    userPoolId: "us-west-2_pool",
    userName: "qa-user",
    callerContext: { awsSdkVersion: "3", clientId: "web-client" },
    triggerSource: "PreSignUp_SignUp",
    request: {
      userAttributes: {},
      validationData: {},
      ...(token ? { clientMetadata: { bootstrapToken: token } } : {}),
    },
    response: {
      autoConfirmUser: false,
      autoVerifyEmail: false,
      autoVerifyPhone: false,
    },
  };
}

describe("Mac-approved Cognito signup", () => {
  beforeEach(() => mocks.send.mockReset());

  it("atomically consumes the one-time Mac grant and auto-confirms without email", async () => {
    mocks.send.mockResolvedValue({});
    const result = await handler(signupEvent("approved-token"), {} as never, () => undefined);

    expect(result.response).toMatchObject({
      autoConfirmUser: true,
      autoVerifyEmail: false,
      autoVerifyPhone: false,
    });
    const input = mocks.send.mock.calls[0]?.[0].input;
    expect(input.Key).toEqual({
      PK: `ACCOUNT_BOOTSTRAP#${sha256("approved-token")}`,
      SK: "META",
    });
    expect(input.ConditionExpression).toContain("#status = :pending");
    expect(input.ExpressionAttributeValues).toMatchObject({
      ":client": "web-client",
      ":username": "qa-user",
    });
  });

  it("rejects direct public signup without a Mac grant", async () => {
    await expect(handler(signupEvent(), {} as never, () => undefined))
      .rejects.toThrow("Open TerminalDB on a Mac");
    expect(mocks.send).not.toHaveBeenCalled();
  });
});
