import { GetCommand, UpdateCommand } from "@aws-sdk/lib-dynamodb";
import type {
  PostConfirmationTriggerEvent,
  PreSignUpTriggerEvent,
} from "aws-lambda";

import { constantEqual, dynamo, nowSeconds, sha256, tableName } from "./common.js";

type SignupEvent = PreSignUpTriggerEvent | PostConfirmationTriggerEvent;

const PREPARED = "signup-prepared";
const CONFIRMED = "signup-confirmed";

function bootstrapToken(event: SignupEvent): string {
  const value = event.request.clientMetadata?.bootstrapToken;
  if (typeof value !== "string" || value.length < 32 || value.length > 256) {
    throw new Error("Account creation must start from TerminalDB on an approved Mac");
  }
  return value;
}

function bootstrapKey(token: string): { PK: string; SK: string } {
  return { PK: `ACCOUNT_BOOTSTRAP#${sha256(token)}`, SK: "META" };
}

async function reserveBootstrap(event: PreSignUpTriggerEvent): Promise<void> {
  const token = bootstrapToken(event);
  const key = bootstrapKey(token);
  const now = nowSeconds();
  const current = await dynamo.send(new GetCommand({
    TableName: tableName,
    Key: key,
    ConsistentRead: true,
  }));
  const bootstrap = current.Item;
  const currentStatus = bootstrap?.status;
  const samePreparedSignup = (
    (currentStatus === PREPARED || currentStatus === CONFIRMED) &&
    typeof bootstrap?.cognitoUsername === "string" &&
    constantEqual(bootstrap.cognitoUsername, event.userName)
  );
  if (
    !bootstrap ||
    Number(bootstrap.ttl) <= now ||
    bootstrap.clientId !== event.callerContext.clientId ||
    (currentStatus !== "pending" && !samePreparedSignup)
  ) {
    throw new Error("This Mac approval is invalid or has expired. Start account creation again.");
  }
  if (currentStatus === CONFIRMED) return;

  try {
    await dynamo.send(new UpdateCommand({
      TableName: tableName,
      Key: key,
      UpdateExpression: "SET #status = :prepared, cognitoUsername = :username",
      ConditionExpression:
        "#ttl > :now AND clientId = :client AND (#status = :pending OR (#status = :prepared AND cognitoUsername = :username))",
      ExpressionAttributeNames: { "#status": "status", "#ttl": "ttl" },
      ExpressionAttributeValues: {
        ":prepared": PREPARED,
        ":pending": "pending",
        ":username": event.userName,
        ":client": event.callerContext.clientId,
        ":now": now,
      },
    }));
  } catch (error) {
    if ((error as { name?: string }).name === "ConditionalCheckFailedException") {
      throw new Error("This Mac approval is invalid or has expired. Start account creation again.");
    }
    throw error;
  }
}

async function confirmBootstrap(event: PostConfirmationTriggerEvent): Promise<void> {
  const token = bootstrapToken(event);
  try {
    await dynamo.send(new UpdateCommand({
      TableName: tableName,
      Key: bootstrapKey(token),
      UpdateExpression: "SET #status = :confirmed",
      ConditionExpression:
        "#ttl > :now AND cognitoUsername = :username AND (#status = :prepared OR #status = :confirmed)",
      ExpressionAttributeNames: { "#status": "status", "#ttl": "ttl" },
      ExpressionAttributeValues: {
        ":prepared": PREPARED,
        ":confirmed": CONFIRMED,
        ":username": event.userName,
        ":now": nowSeconds(),
      },
    }));
  } catch (error) {
    if ((error as { name?: string }).name === "ConditionalCheckFailedException") {
      throw new Error("This Mac approval is invalid or has expired. Start account creation again.");
    }
    throw error;
  }
}

export const handler = async (event: SignupEvent): Promise<SignupEvent> => {
  if (!event.callerContext.clientId) {
    throw new Error("Account signup must use TerminalDB's secure Cognito flow");
  }
  if (event.triggerSource === "PreSignUp_SignUp") {
    await reserveBootstrap(event);
    event.response.autoConfirmUser = true;
    event.response.autoVerifyEmail = false;
    event.response.autoVerifyPhone = false;
    return event;
  }
  if (event.triggerSource === "PostConfirmation_ConfirmSignUp") {
    await confirmBootstrap(event);
    return event;
  }
  throw new Error("Account signup must use TerminalDB's secure Cognito flow");
};
