#!/usr/bin/env node
import { App, Aspects, Tags } from "aws-cdk-lib";
import { AwsSolutionsChecks } from "cdk-nag";

import { TerminalDBRemoteEdgeStack } from "../lib/edge-stack.js";
import { readLocalConfig } from "../lib/local-config.js";
import { TerminalDBRemoteStack } from "../lib/remote-stack.js";

const app = new App();
const localConfig = readLocalConfig();
const stage = String(app.node.tryGetContext("stage") ?? "dev");
if (!["dev", "prod"].includes(stage)) throw new Error("CDK context stage must be dev or prod");
const region = String(app.node.tryGetContext("region") ?? "us-west-2");
const account = process.env.CDK_DEFAULT_ACCOUNT;
if (!account) throw new Error("Run CDK with an AWS profile so CDK_DEFAULT_ACCOUNT is available");
const crossRegionReferences = true;
const edge = new TerminalDBRemoteEdgeStack(app, `TerminalDBRemote-${stage}-Edge`, {
  env: { account, region: "us-east-1" },
  crossRegionReferences,
  description: "TerminalDB Remote global WAF",
});
const remote = new TerminalDBRemoteStack(app, `TerminalDBRemote-${stage}`, {
  env: { account, region },
  crossRegionReferences,
  description: "Cost-optimized encrypted relay and private web origin for TerminalDB Remote",
  stage: stage as "dev" | "prod",
  webAclArn: edge.webAclArn,
  disableNewPairings: String(app.node.tryGetContext("disableNewPairings")) === "true",
  websocketMessagesPerSecond: Number(app.node.tryGetContext("websocketMessagesPerSecond") ?? 50),
  websocketBurst: Number(app.node.tryGetContext("websocketBurst") ?? 100),
  lambdaReservedConcurrency: Number(app.node.tryGetContext("lambdaReservedConcurrency") ?? 8),
  budgetEmail: (app.node.tryGetContext("budgetEmail") as string | undefined) ?? localConfig.budgetEmail,
  cloudfrontPlan: String(app.node.tryGetContext("cloudfrontPlan") ?? "FREE") === "PAYG" ? "PAYG" : "FREE",
  domainName: app.node.tryGetContext("domainName") as string | undefined,
  certificateArn: app.node.tryGetContext("certificateArn") as string | undefined,
  cognitoFromEmail: app.node.tryGetContext("cognitoFromEmail") as string | undefined,
  cognitoFromName: app.node.tryGetContext("cognitoFromName") as string | undefined,
  cognitoReplyTo: app.node.tryGetContext("cognitoReplyTo") as string | undefined,
  cognitoSesRegion: app.node.tryGetContext("cognitoSesRegion") as string | undefined,
});
remote.addStackDependency(edge);
for (const stack of [edge, remote]) {
  Tags.of(stack).add("Project", "TerminalDBRemote");
  Tags.of(stack).add("Stage", stage);
  Tags.of(stack).add("ManagedBy", "CDK");
}
Aspects.of(app).add(new AwsSolutionsChecks({ verbose: true }));
