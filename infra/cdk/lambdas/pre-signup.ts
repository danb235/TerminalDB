import type { PreSignUpTriggerHandler } from "aws-lambda";

export const handler: PreSignUpTriggerHandler = async (event) => {
  if (
    event.triggerSource !== "PreSignUp_SignUp" ||
    !event.callerContext.clientId
  ) {
    throw new Error("Account signup must use TerminalDB's secure Cognito flow");
  }
  event.response.autoConfirmUser = true;
  event.response.autoVerifyEmail = false;
  event.response.autoVerifyPhone = false;
  return event;
};
