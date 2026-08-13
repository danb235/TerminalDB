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

  it("caps all four application Lambdas and uses arm64", () => {
    template.hasResourceProperties("AWS::Lambda::Function", {
      Architectures: ["arm64"],
      ReservedConcurrentExecutions: 8,
    });
    const applicationFunctions = Object.values(
      template.findResources("AWS::Lambda::Function", {
        Properties: { ReservedConcurrentExecutions: 8 },
      }),
    );
    expect(applicationFunctions).toHaveLength(4);
  });

  it("provisions Mac-approved email-free Cognito accounts and JWT-protects account routes", () => {
    template.hasResourceProperties("AWS::Cognito::UserPool", {
      UsernameConfiguration: { CaseSensitive: false },
      MfaConfiguration: "ON",
      UserPoolTier: "PLUS",
      UserPoolAddOns: { AdvancedSecurityMode: "ENFORCED" },
      AccountRecoverySetting: {
        RecoveryMechanisms: [{ Name: "admin_only", Priority: 1 }],
      },
      Policies: {
        PasswordPolicy: Match.objectLike({ MinimumLength: 12 }),
        SignInPolicy: {
          AllowedFirstAuthFactors: ["PASSWORD"],
        },
      },
    });
    const userPools = Object.values(template.findResources("AWS::Cognito::UserPool"));
    expect(userPools).toHaveLength(1);
    expect(JSON.stringify(userPools[0])).not.toContain("WEB_AUTHN");
    expect(JSON.stringify(userPools[0])).not.toContain("WebAuthn");
    template.hasResourceProperties("AWS::Cognito::UserPoolClient", {
      AllowedOAuthFlows: ["code"],
      AllowedOAuthScopes: Match.arrayWith([
        "openid",
        "profile",
        "aws.cognito.signin.user.admin",
      ]),
      PreventUserExistenceErrors: "ENABLED",
      GenerateSecret: false,
    });
    template.hasResourceProperties("AWS::Cognito::ManagedLoginBranding", {
      Assets: Match.arrayWith([
        Match.objectLike({
          Category: "FORM_LOGO",
          ColorMode: "DARK",
          Extension: "SVG",
        }),
        Match.objectLike({
          Category: "FAVICON_SVG",
          ColorMode: "DARK",
          Extension: "SVG",
        }),
      ]),
      ClientId: Match.anyValue(),
      Settings: Match.objectLike({
        categories: Match.objectLike({
          global: Match.objectLike({ colorSchemeMode: "DARK" }),
        }),
        components: Match.objectLike({
          form: Match.objectLike({
            darkMode: {
              backgroundColor: "1c1c20ff",
              borderColor: "3b3b43ff",
            },
          }),
          pageBackground: Match.objectLike({
            darkMode: { color: "101013ff" },
            image: { enabled: false },
          }),
          primaryButton: Match.objectLike({
            darkMode: Match.objectLike({
              defaults: Match.objectLike({ backgroundColor: "52d0ddff" }),
            }),
          }),
        }),
      }),
      UserPoolId: Match.anyValue(),
    });
    const brandingResources = Object.values(
      template.findResources("AWS::Cognito::ManagedLoginBranding"),
    );
    expect(brandingResources).toHaveLength(1);
    expect(JSON.stringify(brandingResources[0])).not.toContain(
      "UseCognitoProvidedValues",
    );
    template.hasResourceProperties("AWS::ApiGatewayV2::Authorizer", {
      AuthorizerType: "JWT",
      IdentitySource: ["$request.header.Authorization"],
    });
    template.hasResourceProperties("AWS::ApiGatewayV2::Route", {
      RouteKey: "ANY /api/v1/account/{proxy+}",
      AuthorizationType: "JWT",
      AuthorizationScopes: ["openid", "aws.cognito.signin.user.admin"],
    });
    template.hasResourceProperties("AWS::Lambda::Function", {
      FunctionName: "terminaldb-remote-dev-control",
      Environment: {
        Variables: Match.objectLike({
          COGNITO_AUTH_ENABLED: "true",
          COGNITO_CLIENT_ID: Match.anyValue(),
          COGNITO_DOMAIN: Match.anyValue(),
          COGNITO_ISSUER: Match.anyValue(),
          COGNITO_USER_POOL_ID: Match.anyValue(),
        }),
      },
    });
    template.hasResourceProperties("AWS::ApiGatewayV2::Route", {
      RouteKey: "DELETE /api/v1/account",
      AuthorizationType: "JWT",
      AuthorizationScopes: ["openid", "aws.cognito.signin.user.admin"],
    });
    const policies = Object.values(template.findResources("AWS::IAM::Policy"))
      .map((resource) => JSON.stringify(resource));
    const accountDeletionPolicy = policies.find((policy) =>
      policy.includes("cognito-idp:AdminDeleteUser") &&
      policy.includes("cognito-idp:AdminUserGlobalSignOut"),
    );
    expect(accountDeletionPolicy).toBeDefined();
    expect(accountDeletionPolicy).not.toContain('"Resource":"*"');
    expect(accountDeletionPolicy).toContain("cognito-idp:AdminSetUserPassword");
    template.hasResourceProperties("AWS::Cognito::UserPool", {
      LambdaConfig: {
        PreSignUp: Match.anyValue(),
        PostConfirmation: Match.anyValue(),
      },
    });
    template.hasResourceProperties("AWS::Lambda::Function", {
      FunctionName: "terminaldb-remote-dev-pre-signup",
      Environment: {
        Variables: Match.objectLike({ TABLE_NAME: Match.anyValue() }),
      },
    });
    const preSignupPolicy = Object.entries(template.findResources("AWS::IAM::Policy"))
      .find(([logicalId]) => logicalId.includes("PreSignupFunction"));
    expect(preSignupPolicy).toBeDefined();
    expect(JSON.stringify(preSignupPolicy?.[1])).toContain("dynamodb:GetItem");
    expect(JSON.stringify(preSignupPolicy?.[1])).toContain("dynamodb:UpdateItem");
    expect(userPools.every((pool) => !JSON.stringify(pool).includes("AutoVerifiedAttributes"))).toBe(true);
    expect(userPools.every((pool) => !JSON.stringify(pool).includes("EmailConfiguration"))).toBe(true);
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
          Match.objectLike({ PathPattern: "/auth-status.html" }),
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

  it("frames only the minimal account-status bridge from TerminalDB marketing", () => {
    template.resourceCountIs("AWS::CloudFront::ResponseHeadersPolicy", 2);
    const policies = Object.values(
      template.findResources("AWS::CloudFront::ResponseHeadersPolicy"),
    );
    const accountStatus = policies.find((policy) =>
      JSON.stringify(policy).includes("AccountStatus"),
    );
    expect(accountStatus).toBeDefined();
    expect(JSON.stringify(accountStatus)).toContain("TerminalDBRemote-dev-AccountStatus");
    expect(JSON.stringify(accountStatus)).toContain(
      "frame-ancestors https://terminaldb.app https://www.terminaldb.app",
    );
    expect(JSON.stringify(accountStatus)).not.toContain("FrameOption");
    const defaultPolicy = policies.find((policy) =>
      JSON.stringify(policy).includes("Security") && policy !== accountStatus,
    );
    expect(JSON.stringify(defaultPolicy)).toContain("frame-ancestors 'none'");
    expect(JSON.stringify(defaultPolicy)).toContain('"FrameOption":"DENY"');
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

  it("requires branded application and Cognito domains in production but no email sender", () => {
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
    expect(() => new TerminalDBRemoteStack(prodApp, "ProdNoEmail", {
      ...baseProps,
      domainName: "remote.example.invalid",
      certificateArn:
        "arn:aws:acm:us-east-1:111111111111:certificate/00000000-0000-4000-8000-000000000000",
      authDomainName: "auth.example.invalid",
      authCertificateArn:
        "arn:aws:acm:us-east-1:111111111111:certificate/00000000-0000-4000-8000-000000000000",
    })).not.toThrow();
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
      authDomainName: "auth.example.invalid",
      authCertificateArn:
        "arn:aws:acm:us-east-1:111111111111:certificate/00000000-0000-4000-8000-000000000000",
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
      }),
    });
    const prodPools = Object.values(prodTemplate.findResources("AWS::Cognito::UserPool"));
    expect(prodPools.every((pool) => !JSON.stringify(pool).includes("EmailConfiguration"))).toBe(true);
    prodTemplate.hasResource("AWS::S3::Bucket", {
      DeletionPolicy: "Retain",
      UpdateReplacePolicy: "Retain",
    });
  });
});
