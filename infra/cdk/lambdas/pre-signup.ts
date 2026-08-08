import { UpdateCommand } from "@aws-sdk/lib-dynamodb";
import type { PreSignUpTriggerHandler } from "aws-lambda";

import { dynamo, nowSeconds, sha256, tableName } from "./common.js";

const COMPLETION_TTL_SECONDS = 30 * 60;

export const handler: PreSignUpTriggerHandler = async (event) => {
  if (
    event.triggerSource !== "PreSignUp_SignUp"
  ) {
    throw new Error("Account signup must start from TerminalDB on a Mac");
  }
  const bootstrapToken = event.request.clientMetadata?.bootstrapToken;
  if (!bootstrapToken || bootstrapToken.length > 256) {
    throw new Error("Open TerminalDB on a Mac to create an account");
  }
  const now = nowSeconds();
  await dynamo.send(
    new UpdateCommand({
      TableName: tableName,
      Key: { PK: `ACCOUNT_BOOTSTRAP#${sha256(bootstrapToken)}`, SK: "META" },
      UpdateExpression:
        "SET #status = :confirmed, cognitoUsername = :username, signupConfirmedAt = :now, #ttl = :ttl",
      ConditionExpression:
        "#status = :pending AND expiresAt > :now AND clientId = :client",
      ExpressionAttributeNames: {
        "#status": "status",
        "#ttl": "ttl",
      },
      ExpressionAttributeValues: {
        ":pending": "pending",
        ":confirmed": "signup-confirmed",
        ":username": event.userName,
        ":now": now,
        ":ttl": now + COMPLETION_TTL_SECONDS,
        ":client": event.callerContext.clientId,
      },
    }),
  );
  event.response.autoConfirmUser = true;
  event.response.autoVerifyEmail = false;
  event.response.autoVerifyPhone = false;
  return event;
};
