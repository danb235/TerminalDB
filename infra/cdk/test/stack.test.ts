import { App } from "aws-cdk-lib";
import { Match, Template } from "aws-cdk-lib/assertions";
import { describe, expect, it } from "vitest";

import { TerminalDBRemoteEdgeStack } from "../lib/edge-stack.js";
import { TerminalDBRemoteStack } from "../lib/remote-stack.js";

describe("TerminalDB Remote infrastructure", () => {
  const app = new App();
  const edge = new TerminalDBRemoteEdgeStack(app, "Edge", {
    env: { account: "111111111111", region: "us-east-1" },
  });
  const stack = new TerminalDBRemoteStack(app, "Remote", {
    env: { account: "111111111111", region: "us-west-2" },
    stage: "dev",
    webAclArn: edge.webAclArn,
    disableNewPairings: false,
    websocketMessagesPerSecond: 25,
    websocketBurst: 50,
    lambdaReservedConcurrency: 8,
    cloudfrontPlan: "PAYG",
    budgetEmail: "alerts@example.invalid",
  });
  const template = Template.fromStack(stack);

  it("uses one on-demand encrypted DynamoDB table with TTL and recovery", () => {
    template.hasResourceProperties("AWS::DynamoDB::Table", {
      BillingMode: "PAY_PER_REQUEST",
      SSESpecification: { SSEEnabled: true },
      TimeToLiveSpecification: { AttributeName: "ttl", Enabled: true },
      PointInTimeRecoverySpecification: { PointInTimeRecoveryEnabled: true },
    });
    expect(Object.keys(template.findResources("AWS::DynamoDB::Table"))).toHaveLength(1);
  });

  it("caps all three application Lambdas and uses arm64", () => {
    template.hasResourceProperties("AWS::Lambda::Function", {
      Architectures: ["arm64"],
      ReservedConcurrentExecutions: 8,
    });
    const applicationFunctions = Object.values(
      template.findResources("AWS::Lambda::Function", {
        Properties: { ReservedConcurrentExecutions: 8 },
      }),
    );
    expect(applicationFunctions).toHaveLength(3);
  });

  it("provisions self-service Cognito accounts and JWT-protects every account route", () => {
    template.hasResourceProperties("AWS::Cognito::UserPool", {
      AutoVerifiedAttributes: ["email"],
      UsernameConfiguration: { CaseSensitive: false },
      MfaConfiguration: "ON",
      UserPoolTier: "PLUS",
      UserPoolAddOns: { AdvancedSecurityMode: "ENFORCED" },
      Policies: {
        PasswordPolicy: Match.objectLike({ MinimumLength: 12 }),
      },
    });
    template.hasResourceProperties("AWS::Cognito::UserPoolClient", {
      AllowedOAuthFlows: ["code"],
      PreventUserExistenceErrors: "ENABLED",
      GenerateSecret: false,
    });
    template.hasResourceProperties("AWS::ApiGatewayV2::Authorizer", {
      AuthorizerType: "JWT",
      IdentitySource: ["$request.header.Authorization"],
    });
    template.hasResourceProperties("AWS::ApiGatewayV2::Route", {
      RouteKey: "ANY /api/v1/account/{proxy+}",
      AuthorizationType: "JWT",
      AuthorizationScopes: ["openid"],
    });
    template.hasResourceProperties("AWS::Lambda::Function", {
      FunctionName: "terminaldb-remote-dev-control",
      Environment: {
        Variables: Match.objectLike({
          COGNITO_AUTH_ENABLED: "true",
          COGNITO_CLIENT_ID: Match.anyValue(),
          COGNITO_DOMAIN: Match.anyValue(),
          COGNITO_ISSUER: Match.anyValue(),
        }),
      },
    });
  });

  it("keeps the web bucket private and relays WebSockets through CloudFront", () => {
    template.hasResourceProperties("AWS::S3::Bucket", {
      PublicAccessBlockConfiguration: {
        BlockPublicAcls: true,
        BlockPublicPolicy: true,
        IgnorePublicAcls: true,
        RestrictPublicBuckets: true,
      },
    });
    template.hasResourceProperties("AWS::CloudFront::Distribution", {
      DistributionConfig: Match.objectLike({
        CacheBehaviors: Match.arrayWith([
          Match.objectLike({ PathPattern: "/api/*" }),
        ]),
      }),
    });
    template.hasResourceProperties("AWS::CloudFront::Distribution", {
      DistributionConfig: Match.objectLike({
        CacheBehaviors: Match.arrayWith([
          Match.objectLike({
            PathPattern: "/socket*",
            TargetOriginId: Match.anyValue(),
          }),
        ]),
        CustomErrorResponses: Match.absent(),
      }),
    });
    const distribution = Object.values(
      template.findResources("AWS::CloudFront::Distribution"),
    )[0] as {
      Properties: {
        DistributionConfig: {
          Origins: Array<{ DomainName: string; OriginPath?: string }>;
        };
      };
    };
    const socketOrigin = distribution.Properties.DistributionConfig.Origins.find(
      (origin) => String(origin.DomainName).includes("execute-api"),
    );
    expect(socketOrigin?.OriginPath).toBeUndefined();
    template.hasResourceProperties("AWS::CloudFront::Function", {
      FunctionCode: Match.stringLikeRegexp("r\\.uri\\.replace.*'/dev'"),
    });
    template.resourceCountIs("AWS::CloudFront::Function", 2);
  });

  it("grants API Gateway permission to invoke every WebSocket lifecycle route", () => {
    const permissions = Object.values(
      template.findResources("AWS::Lambda::Permission"),
    ).map((resource) => JSON.stringify(resource));
    expect(permissions.some((permission) => permission.includes("/*$connect"))).toBe(true);
    expect(permissions.some((permission) => permission.includes("/*$disconnect"))).toBe(true);
    expect(permissions.some((permission) => permission.includes("/*$default"))).toBe(true);
  });

  it("allows the control Lambda to close revoked and ended controller sockets", () => {
    template.hasResourceProperties("AWS::Lambda::Function", {
      FunctionName: "terminaldb-remote-dev-control",
      Environment: {
        Variables: Match.objectLike({
          WEBSOCKET_MANAGEMENT_ENDPOINT: Match.anyValue(),
        }),
      },
    });
    const policies = Object.values(
      template.findResources("AWS::IAM::Policy"),
    ).map((resource) => JSON.stringify(resource));
    expect(
      policies.filter((policy) => policy.includes("execute-api:ManageConnections")),
    ).toHaveLength(2);
  });

  it("creates both personal spend budgets", () => {
    template.resourceCountIs("AWS::Budgets::Budget", 2);
    template.hasResourceProperties("AWS::SNS::Subscription", {
      Endpoint: "alerts@example.invalid",
      Protocol: "email",
    });
  });

  it("refuses production without a custom domain, certificate, and verified SES sender", () => {
    const prodApp = new App();
    const baseProps = {
      env: { account: "111111111111", region: "us-west-2" },
      stage: "prod" as const,
      webAclArn:
        "arn:aws:wafv2:us-east-1:111111111111:global/webacl/terminaldb-test/00000000-0000-4000-8000-000000000000",
      disableNewPairings: false,
      websocketMessagesPerSecond: 25,
      websocketBurst: 50,
      lambdaReservedConcurrency: 8,
      cloudfrontPlan: "PAYG" as const,
    };

    expect(
      () => new TerminalDBRemoteStack(prodApp, "ProdMissingDomain", baseProps),
    ).toThrow("Production requires a custom domain");
    expect(
      () =>
        new TerminalDBRemoteStack(prodApp, "ProdMissingSes", {
          ...baseProps,
          domainName: "remote.example.invalid",
          certificateArn:
            "arn:aws:acm:us-east-1:111111111111:certificate/00000000-0000-4000-8000-000000000000",
        }),
    ).toThrow("Production requires a verified SES cognitoFromEmail");
  });

  it("retains and deletion-protects production identity and tenant state", () => {
    const prodApp = new App();
    const prodStack = new TerminalDBRemoteStack(prodApp, "Prod", {
      env: { account: "111111111111", region: "us-west-2" },
      stage: "prod",
      webAclArn:
        "arn:aws:wafv2:us-east-1:111111111111:global/webacl/terminaldb-test/00000000-0000-4000-8000-000000000000",
      disableNewPairings: false,
      websocketMessagesPerSecond: 25,
      websocketBurst: 50,
      lambdaReservedConcurrency: 8,
      cloudfrontPlan: "PAYG",
      domainName: "remote.example.invalid",
      certificateArn:
        "arn:aws:acm:us-east-1:111111111111:certificate/00000000-0000-4000-8000-000000000000",
      cognitoFromEmail: "no-reply@example.invalid",
      cognitoFromName: "TerminalDB QA",
      cognitoReplyTo: "support@example.invalid",
      cognitoSesRegion: "us-west-2",
    });
    const prodTemplate = Template.fromStack(prodStack);

    prodTemplate.hasResource("AWS::DynamoDB::Table", {
      DeletionPolicy: "Retain",
      UpdateReplacePolicy: "Retain",
      Properties: Match.objectLike({ DeletionProtectionEnabled: true }),
    });
    prodTemplate.hasResource("AWS::Cognito::UserPool", {
      DeletionPolicy: "Retain",
      UpdateReplacePolicy: "Retain",
      Properties: Match.objectLike({
        DeletionProtection: "ACTIVE",
        EmailConfiguration: Match.objectLike({
          EmailSendingAccount: "DEVELOPER",
          From: "TerminalDB QA <no-reply@example.invalid>",
          ReplyToEmailAddress: "support@example.invalid",
          SourceArn: Match.anyValue(),
        }),
      }),
    });
    prodTemplate.hasResource("AWS::S3::Bucket", {
      DeletionPolicy: "Retain",
      UpdateReplacePolicy: "Retain",
    });
  });
});
