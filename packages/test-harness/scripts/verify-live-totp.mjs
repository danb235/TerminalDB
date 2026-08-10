#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { createHash, createHmac, randomBytes } from "node:crypto";

import {
  DeleteItemCommand,
  DynamoDBClient,
  PutItemCommand,
} from "@aws-sdk/client-dynamodb";
import {
  AdminDeleteUserCommand,
  AssociateSoftwareTokenCommand,
  CognitoIdentityProviderClient,
  DescribeUserPoolClientCommand,
  DescribeUserPoolCommand,
  GetUserPoolMfaConfigCommand,
  InitiateAuthCommand,
  RespondToAuthChallengeCommand,
  SignUpCommand,
  VerifySoftwareTokenCommand,
} from "@aws-sdk/client-cognito-identity-provider";

function argument(name, fallback) {
  const index = process.argv.indexOf(`--${name}`);
  return index >= 0 && process.argv[index + 1] ? process.argv[index + 1] : fallback;
}

const profile = argument("profile", "stelao");
const region = argument("region", "us-west-2");
const stage = argument("stage", "dev");
const stackName = argument("stack", `TerminalDBRemote-${stage}`);
process.env.AWS_PROFILE = profile;

function stackOutput(key) {
  return execFileSync(
    "aws",
    [
      "cloudformation",
      "describe-stacks",
      "--stack-name",
      stackName,
      "--profile",
      profile,
      "--region",
      region,
      "--query",
      `Stacks[0].Outputs[?OutputKey=='${key}'].OutputValue | [0]`,
      "--output",
      "text",
    ],
    { encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] },
  ).trim();
}

function stackResource(resourceType) {
  return execFileSync(
    "aws",
    [
      "cloudformation",
      "describe-stack-resources",
      "--stack-name",
      stackName,
      "--profile",
      profile,
      "--region",
      region,
      "--query",
      `StackResources[?ResourceType=='${resourceType}'].PhysicalResourceId | [0]`,
      "--output",
      "text",
    ],
    { encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] },
  ).trim();
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const base32Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

function decodeBase32(value) {
  let bits = "";
  for (const character of value.replace(/=+$/u, "").toUpperCase()) {
    const index = base32Alphabet.indexOf(character);
    if (index < 0) throw new Error("Cognito returned an invalid TOTP secret");
    bits += index.toString(2).padStart(5, "0");
  }
  const bytes = [];
  for (let index = 0; index + 8 <= bits.length; index += 8) {
    bytes.push(Number.parseInt(bits.slice(index, index + 8), 2));
  }
  return Buffer.from(bytes);
}

function totp(secret, timestamp = Date.now()) {
  const counter = Math.floor(timestamp / 30_000);
  const message = Buffer.alloc(8);
  message.writeBigUInt64BE(BigInt(counter));
  const digest = createHmac("sha1", decodeBase32(secret)).update(message).digest();
  const offset = digest[digest.length - 1] & 0x0f;
  const value = (
    ((digest[offset] & 0x7f) << 24) |
    ((digest[offset + 1] & 0xff) << 16) |
    ((digest[offset + 2] & 0xff) << 8) |
    (digest[offset + 3] & 0xff)
  ) % 1_000_000;
  return value.toString().padStart(6, "0");
}

async function currentTotp(secret, previouslyUsedCode) {
  const remaining = 30 - Math.floor(Date.now() / 1_000) % 30;
  if (remaining <= 3 || totp(secret) === previouslyUsedCode) {
    await new Promise((resolve) => setTimeout(resolve, (remaining + 1) * 1_000));
  }
  return totp(secret);
}

const userPoolId = stackOutput("UserPoolId");
const clientId = stackOutput("UserPoolClientId");
const tableName = stackResource("AWS::DynamoDB::Table");
assert(userPoolId && userPoolId !== "None", "The Cognito user pool output is missing");
assert(clientId && clientId !== "None", "The Cognito app-client output is missing");
assert(tableName && tableName !== "None", "The remote-state table is missing");

const client = new CognitoIdentityProviderClient({ region });
const dynamo = new DynamoDBClient({ region });
const username = `tdb-totp-qa-${Date.now()}-${randomBytes(3).toString("hex")}`;
const password = `Tdb!${randomBytes(18).toString("base64url")}9aA`;
const bootstrapToken = randomBytes(32).toString("base64url");
const bootstrapKey = `ACCOUNT_BOOTSTRAP#${createHash("sha256").update(bootstrapToken).digest("base64url")}`;
let created = false;
let bootstrapCreated = false;

try {
  const [pool, appClient, mfaConfig] = await Promise.all([
    client.send(new DescribeUserPoolCommand({ UserPoolId: userPoolId })),
    client.send(new DescribeUserPoolClientCommand({
      UserPoolId: userPoolId,
      ClientId: clientId,
    })),
    client.send(new GetUserPoolMfaConfigCommand({ UserPoolId: userPoolId })),
  ]);
  assert(pool.UserPool?.MfaConfiguration === "ON", "The user pool does not require MFA");
  assert(
    mfaConfig.MfaConfiguration === "ON" &&
      mfaConfig.SoftwareTokenMfaConfiguration?.Enabled === true,
    "Authenticator-app TOTP is not enabled",
  );
  assert(
    JSON.stringify(pool.UserPool?.UserPoolAddOns ?? {}).includes("ENFORCED"),
    "Cognito threat protection is not enforced",
  );
  const factors = pool.UserPool?.Policies?.SignInPolicy?.AllowedFirstAuthFactors ?? [];
  assert(
    factors.length === 1 && factors[0] === "PASSWORD",
    `Unexpected first-factor configuration: ${factors.join(", ") || "none"}`,
  );
  assert(
    !JSON.stringify(pool.UserPool).includes("WEB_AUTHN"),
    "Passkey authentication is still enabled",
  );
  assert(
    appClient.UserPoolClient?.PreventUserExistenceErrors === "ENABLED",
    "User-existence error suppression is not enabled",
  );
  console.log("PASS pool policy: password plus authenticator-app TOTP only");

  const now = Math.floor(Date.now() / 1_000);
  await dynamo.send(new PutItemCommand({
    TableName: tableName,
    Item: {
      PK: { S: bootstrapKey },
      SK: { S: "META" },
      status: { S: "pending" },
      expiresAt: { N: String(now + 10 * 60) },
      ttl: { N: String(now + 30 * 60) },
      clientId: { S: clientId },
    },
    ConditionExpression: "attribute_not_exists(PK)",
  }));
  bootstrapCreated = true;
  await client.send(new SignUpCommand({
    ClientId: clientId,
    Username: username,
    Password: password,
    ClientMetadata: { bootstrapToken },
  }));
  created = true;

  const first = await client.send(new InitiateAuthCommand({
    AuthFlow: "USER_AUTH",
    ClientId: clientId,
    AuthParameters: {
      USERNAME: username,
      PASSWORD: password,
      PREFERRED_CHALLENGE: "PASSWORD",
    },
  }));
  assert(!first.AuthenticationResult, "Password-only sign-in unexpectedly returned tokens");
  assert(first.ChallengeName === "MFA_SETUP" && first.Session, "New users were not forced into TOTP setup");
  const available = JSON.parse(first.ChallengeParameters?.MFAS_CAN_SETUP ?? "[]");
  assert(
    Array.isArray(available) && available.length === 1 && available[0] === "SOFTWARE_TOKEN_MFA",
    `Unexpected MFA enrollment choices: ${JSON.stringify(available)}`,
  );
  console.log("PASS enrollment gate: password-only sign-in cannot complete");

  const association = await client.send(new AssociateSoftwareTokenCommand({
    Session: first.Session,
  }));
  assert(association.SecretCode && association.Session, "Cognito did not issue a TOTP enrollment secret");
  const enrollmentCode = await currentTotp(association.SecretCode);
  const verification = await client.send(new VerifySoftwareTokenCommand({
    Session: association.Session,
    UserCode: enrollmentCode,
    FriendlyDeviceName: "TerminalDB automated MFA QA",
  }));
  assert(verification.Status === "SUCCESS" && verification.Session, "Cognito rejected the enrollment code");
  const completed = await client.send(new RespondToAuthChallengeCommand({
    ClientId: clientId,
    ChallengeName: "MFA_SETUP",
    ChallengeResponses: { USERNAME: username },
    Session: verification.Session,
  }));
  assert(completed.AuthenticationResult?.AccessToken, "TOTP setup did not complete sign-in");
  console.log("PASS enrollment ceremony: secret, verification, and first sign-in");

  const next = await client.send(new InitiateAuthCommand({
    AuthFlow: "USER_AUTH",
    ClientId: clientId,
    AuthParameters: {
      USERNAME: username,
      PASSWORD: password,
      PREFERRED_CHALLENGE: "PASSWORD",
    },
  }));
  assert(next.ChallengeName === "SOFTWARE_TOKEN_MFA" && next.Session, "Returning sign-in did not require TOTP");
  const validCode = await currentTotp(association.SecretCode, enrollmentCode);
  const invalidCode = ((Number(validCode) + 1) % 1_000_000).toString().padStart(6, "0");
  let invalidRejected = false;
  try {
    await client.send(new RespondToAuthChallengeCommand({
      ClientId: clientId,
      ChallengeName: "SOFTWARE_TOKEN_MFA",
      ChallengeResponses: {
        USERNAME: username,
        SOFTWARE_TOKEN_MFA_CODE: invalidCode,
      },
      Session: next.Session,
    }));
  } catch (error) {
    invalidRejected = error?.name === "CodeMismatchException";
  }
  assert(invalidRejected, "An invalid authenticator code was not rejected");
  console.log("PASS invalid-code handling: Cognito rejected the wrong TOTP");

  const retry = await client.send(new InitiateAuthCommand({
    AuthFlow: "USER_AUTH",
    ClientId: clientId,
    AuthParameters: {
      USERNAME: username,
      PASSWORD: password,
      PREFERRED_CHALLENGE: "PASSWORD",
    },
  }));
  assert(retry.ChallengeName === "SOFTWARE_TOKEN_MFA" && retry.Session, "TOTP retry challenge is missing");
  const signedIn = await client.send(new RespondToAuthChallengeCommand({
    ClientId: clientId,
    ChallengeName: "SOFTWARE_TOKEN_MFA",
    ChallengeResponses: {
      USERNAME: username,
      SOFTWARE_TOKEN_MFA_CODE: validCode,
    },
    Session: retry.Session,
  }));
  assert(signedIn.AuthenticationResult?.AccessToken, "Valid TOTP sign-in did not return an access token");
  console.log("PASS returning sign-in: password and valid TOTP both required");
} finally {
  if (created) {
    await client.send(new AdminDeleteUserCommand({
      UserPoolId: userPoolId,
      Username: username,
    }));
    console.log("PASS cleanup: disposable Cognito account deleted");
  }
  if (bootstrapCreated) {
    await dynamo.send(new DeleteItemCommand({
      TableName: tableName,
      Key: { PK: { S: bootstrapKey }, SK: { S: "META" } },
    }));
  }
}
