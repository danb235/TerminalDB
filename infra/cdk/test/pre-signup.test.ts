import type { PreSignUpTriggerEvent } from "aws-lambda";
import { describe, expect, it } from "vitest";

import { handler } from "../lambdas/pre-signup.js";

function signupEvent(clientId = "web-client"): PreSignUpTriggerEvent {
  return {
    version: "1",
    region: "us-west-2",
    userPoolId: "us-west-2_pool",
    userName: "qa-user",
    callerContext: { awsSdkVersion: "3", clientId },
    triggerSource: "PreSignUp_SignUp",
    request: {
      userAttributes: {},
      validationData: {},
    },
    response: {
      autoConfirmUser: false,
      autoVerifyEmail: false,
      autoVerifyPhone: false,
    },
  };
}

describe("TerminalDB Cognito signup", () => {
  it("auto-confirms managed-login signup without email", async () => {
    const result = await handler(signupEvent(), {} as never, () => undefined);

    expect(result.response).toMatchObject({
      autoConfirmUser: true,
      autoVerifyEmail: false,
      autoVerifyPhone: false,
    });
  });

  it("rejects non-self-service trigger sources", async () => {
    const event = signupEvent();
    event.triggerSource = "PreSignUp_AdminCreateUser";
    await expect(handler(event, {} as never, () => undefined))
      .rejects.toThrow("secure Cognito flow");
  });
});
