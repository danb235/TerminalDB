import * as path from "node:path";

import {
  CfnOutput,
  Duration,
  RemovalPolicy,
  Stack,
  type StackProps,
} from "aws-cdk-lib";
import * as acm from "aws-cdk-lib/aws-certificatemanager";
import * as apigateway from "aws-cdk-lib/aws-apigateway";
import * as apigatewayv2 from "aws-cdk-lib/aws-apigatewayv2";
import * as apigatewayv2Authorizers from "aws-cdk-lib/aws-apigatewayv2-authorizers";
import * as apigatewayv2Integrations from "aws-cdk-lib/aws-apigatewayv2-integrations";
import * as budgets from "aws-cdk-lib/aws-budgets";
import * as cloudfront from "aws-cdk-lib/aws-cloudfront";
import * as cloudfrontOrigins from "aws-cdk-lib/aws-cloudfront-origins";
import * as cloudwatch from "aws-cdk-lib/aws-cloudwatch";
import * as cloudwatchActions from "aws-cdk-lib/aws-cloudwatch-actions";
import * as cognito from "aws-cdk-lib/aws-cognito";
import * as dynamodb from "aws-cdk-lib/aws-dynamodb";
import * as iam from "aws-cdk-lib/aws-iam";
import * as lambda from "aws-cdk-lib/aws-lambda";
import * as lambdaNodejs from "aws-cdk-lib/aws-lambda-nodejs";
import * as logs from "aws-cdk-lib/aws-logs";
import * as s3 from "aws-cdk-lib/aws-s3";
import * as s3deploy from "aws-cdk-lib/aws-s3-deployment";
import * as sns from "aws-cdk-lib/aws-sns";
import * as subscriptions from "aws-cdk-lib/aws-sns-subscriptions";
import { NagSuppressions } from "cdk-nag";
import type { Construct } from "constructs";

import {
  terminalDBManagedLoginAssets,
  terminalDBManagedLoginSettings,
} from "./managed-login-branding.js";

export interface TerminalDBRemoteStackProps extends StackProps {
  readonly stage: "dev" | "prod";
  readonly webAclArn: string;
  readonly disableNewPairings: boolean;
  readonly websocketMessagesPerSecond: number;
  readonly websocketBurst: number;
  readonly lambdaReservedConcurrency: number;
  readonly budgetEmail?: string;
  readonly cloudfrontPlan: "FREE" | "PAYG";
  readonly domainName?: string;
  readonly certificateArn?: string;
  readonly authDomainName?: string;
  readonly authCertificateArn?: string;
}

export class TerminalDBRemoteStack extends Stack {
  constructor(scope: Construct, id: string, props: TerminalDBRemoteStackProps) {
    super(scope, id, props);

    const isProduction = props.stage === "prod";
    if (Boolean(props.domainName) !== Boolean(props.certificateArn)) {
      throw new Error("domainName and certificateArn must be supplied together");
    }
    if (Boolean(props.authDomainName) !== Boolean(props.authCertificateArn)) {
      throw new Error("authDomainName and authCertificateArn must be supplied together");
    }
    if (isProduction && (!props.domainName || !props.certificateArn)) {
      throw new Error("Production requires a custom domain and us-east-1 ACM certificate");
    }
    if (isProduction && (!props.authDomainName || !props.authCertificateArn)) {
      throw new Error("Production requires a custom Cognito domain and us-east-1 ACM certificate");
    }
    const removalPolicy = isProduction ? RemovalPolicy.RETAIN : RemovalPolicy.DESTROY;
    const table = new dynamodb.Table(this, "RemoteState", {
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      partitionKey: { name: "PK", type: dynamodb.AttributeType.STRING },
      sortKey: { name: "SK", type: dynamodb.AttributeType.STRING },
      timeToLiveAttribute: "ttl",
      encryption: dynamodb.TableEncryption.AWS_MANAGED,
      pointInTimeRecoverySpecification: { pointInTimeRecoveryEnabled: true },
      deletionProtection: isProduction,
      removalPolicy,
    });
    const userPool = new cognito.UserPool(this, "UserPoolV2", {
      userPoolName: `terminaldb-remote-${props.stage}-v2`,
      selfSignUpEnabled: true,
      signInAliases: { username: true },
      signInCaseSensitive: false,
      passwordPolicy: {
        minLength: 12,
        requireLowercase: true,
        requireUppercase: true,
        requireDigits: true,
        requireSymbols: true,
        tempPasswordValidity: Duration.days(3),
      },
      mfa: cognito.Mfa.REQUIRED,
      mfaSecondFactor: { sms: false, otp: true },
      signInPolicy: {
        allowedFirstAuthFactors: { password: true },
      },
      featurePlan: cognito.FeaturePlan.PLUS,
      standardThreatProtectionMode:
        cognito.StandardThreatProtectionMode.FULL_FUNCTION,
      accountRecovery: cognito.AccountRecovery.NONE,
      deletionProtection: isProduction,
      removalPolicy,
    });
    const userPoolDomain = userPool.addDomain("UserPoolDomainV2", {
      managedLoginVersion: cognito.ManagedLoginVersion.NEWER_MANAGED_LOGIN,
      ...(props.authDomainName && props.authCertificateArn
        ? {
            customDomain: {
              domainName: props.authDomainName,
              certificate: acm.Certificate.fromCertificateArn(
                this,
                "CognitoCertificate",
                props.authCertificateArn,
              ),
            },
          }
        : {
            cognitoDomain: {
              domainPrefix: `terminaldb-v2-${props.stage}-${this.account}-${this.region}`,
            },
          }),
    });
    const cognitoDomainUrl = userPoolDomain.baseUrl();

    const lambdaEnvironment = {
      TABLE_NAME: table.tableName,
      STAGE: props.stage,
      DISABLE_NEW_PAIRINGS: String(props.disableNewPairings),
      NODE_OPTIONS: "--enable-source-maps",
    };
    const createFunction = (
      logicalId: string,
      entry: string,
      timeout: Duration,
    ): lambdaNodejs.NodejsFunction => {
      const functionName = `terminaldb-remote-${props.stage}-${entry}`;
      const logGroup = new logs.LogGroup(this, `${logicalId}Logs`, {
        logGroupName: `/aws/lambda/${functionName}`,
        retention: logs.RetentionDays.ONE_WEEK,
        removalPolicy,
      });
      const role = new iam.Role(this, `${logicalId}Role`, {
        assumedBy: new iam.ServicePrincipal("lambda.amazonaws.com"),
        description: `Least-privilege execution role for ${functionName}`,
      });
      logGroup.grantWrite(role);
      NagSuppressions.addResourceSuppressions(
        role,
        [
          {
            id: "AwsSolutions-IAM5",
            reason:
              "CloudWatch log streams and WebSocket connection IDs are generated at runtime; wildcard suffixes remain scoped to this function's log group and, for relay/control lifecycle cleanup, this WebSocket API.",
          },
        ],
        true,
      );
      const functionResource = new lambdaNodejs.NodejsFunction(this, logicalId, {
        functionName,
        role,
        runtime: lambda.Runtime.NODEJS_24_X,
        architecture: lambda.Architecture.ARM_64,
        entry: path.join(process.cwd(), "lambdas", `${entry}.ts`),
        handler: "handler",
        memorySize: 256,
        timeout,
        reservedConcurrentExecutions: props.lambdaReservedConcurrency,
        environment: lambdaEnvironment,
        logGroup,
        tracing: lambda.Tracing.DISABLED,
        bundling: {
          minify: true,
          sourceMap: false,
          target: "node24",
        },
      });
      NagSuppressions.addResourceSuppressions(
        functionResource,
        [
          {
            id: "AwsSolutions-IAM5",
            reason:
              "The only wildcard required by the base role is the runtime-generated CloudWatch Logs stream suffix inside this function's dedicated seven-day log group.",
          },
        ],
        true,
      );
      return functionResource;
    };

    const controlFunction = createFunction("ControlFunction", "control", Duration.seconds(30));
    const connectionFunction = createFunction("ConnectionFunction", "connection", Duration.seconds(5));
    const relayFunction = createFunction("RelayFunction", "relay", Duration.seconds(5));
    const preSignupFunction = createFunction("PreSignupFunction", "pre-signup", Duration.seconds(5));
    table.grantReadWriteData(controlFunction);
    table.grantReadWriteData(connectionFunction);
    table.grantReadWriteData(relayFunction);

    const relayIntegration = new apigatewayv2Integrations.WebSocketLambdaIntegration(
      "RelayIntegration",
      relayFunction,
    );
    const connectIntegration = new apigatewayv2Integrations.WebSocketLambdaIntegration(
      "ConnectIntegration",
      connectionFunction,
    );
    const disconnectIntegration = new apigatewayv2Integrations.WebSocketLambdaIntegration(
      "DisconnectIntegration",
      connectionFunction,
    );
    const ticketAuthorizer = new apigatewayv2Authorizers.WebSocketLambdaAuthorizer(
      "TicketAuthorizer",
      connectionFunction,
      { identitySource: ["route.request.querystring.ticket"] },
    );
    const webSocketApi = new apigatewayv2.WebSocketApi(this, "RelayApi", {
      apiName: `terminaldb-remote-${props.stage}-relay`,
      routeSelectionExpression: "$request.body.route",
      connectRouteOptions: {
        integration: connectIntegration,
        authorizer: ticketAuthorizer,
      },
      disconnectRouteOptions: { integration: disconnectIntegration },
      defaultRouteOptions: { integration: relayIntegration },
    });
    const socketLogGroup = new logs.LogGroup(this, "SocketAccessLogs", {
      retention: logs.RetentionDays.ONE_WEEK,
      removalPolicy,
    });
    const webSocketStage = new apigatewayv2.WebSocketStage(this, "RelayStage", {
      webSocketApi,
      stageName: props.stage,
      autoDeploy: true,
      throttle: {
        rateLimit: props.websocketMessagesPerSecond,
        burstLimit: props.websocketBurst,
      },
      accessLogSettings: {
        destination: new apigatewayv2.LogGroupLogDestination(socketLogGroup),
        format: apigateway.AccessLogFormat.custom(
          '{"requestId":"$context.requestId","route":"$context.routeKey","status":"$context.status","responseLength":"$context.responseLength"}',
        ),
      },
    });
    webSocketApi.grantManageConnections(relayFunction);
    webSocketApi.grantManageConnections(controlFunction);
    controlFunction.addEnvironment(
      "WEBSOCKET_MANAGEMENT_ENDPOINT",
      `https://${webSocketApi.apiId}.execute-api.${this.region}.${this.urlSuffix}/${props.stage}`,
    );
    NagSuppressions.addResourceSuppressions(
      relayFunction,
      [
        {
          id: "AwsSolutions-IAM5",
          reason:
            "PostToConnection must address a runtime connection ID. Permission remains scoped to this WebSocket API and the relay stage.",
        },
      ],
      true,
    );
    NagSuppressions.addResourceSuppressions(
      controlFunction,
      [
        {
          id: "AwsSolutions-IAM5",
          reason:
            "DeleteConnection must address runtime controller connection IDs. Permission remains scoped to this WebSocket API and relay stage and is used only for revocation and session-end cleanup.",
        },
      ],
      true,
    );
    NagSuppressions.addResourceSuppressions(
      webSocketApi,
      [
        {
          id: "AwsSolutions-APIG4",
          reason:
            "$connect atomically consumes a signed 60-second ticket. API Gateway only invokes $default and $disconnect after that authenticated upgrade.",
        },
      ],
      true,
    );

    const httpIntegration = new apigatewayv2Integrations.HttpLambdaIntegration(
      "ControlIntegration",
      controlFunction,
    );
    const httpLogGroup = new logs.LogGroup(this, "HttpAccessLogs", {
      retention: logs.RetentionDays.ONE_WEEK,
      removalPolicy,
    });
    const httpApi = new apigatewayv2.HttpApi(this, "ControlApi", {
      apiName: `terminaldb-remote-${props.stage}-control`,
      createDefaultStage: false,
      disableExecuteApiEndpoint: false,
    });
    httpApi.addRoutes({
      path: "/{proxy+}",
      methods: [apigatewayv2.HttpMethod.ANY],
      integration: httpIntegration,
    });
    const httpStage = new apigatewayv2.HttpStage(this, "ControlStage", {
      httpApi,
      stageName: "$default",
      autoDeploy: true,
      throttle: { rateLimit: 10, burstLimit: 20 },
      accessLogSettings: {
        destination: new apigatewayv2.LogGroupLogDestination(httpLogGroup),
        format: apigateway.AccessLogFormat.custom(
          '{"requestId":"$context.requestId","method":"$context.httpMethod","path":"$context.routeKey","status":"$context.status","responseLength":"$context.responseLength"}',
        ),
      },
    });
    NagSuppressions.addResourceSuppressions(
      httpApi,
      [
        {
          id: "AwsSolutions-APIG4",
          reason:
            "The public config and one-time pairing redemption routes are intentionally unauthenticated. All other control routes verify a P-256 signed request and a one-time nonce inside the control Lambda.",
        },
      ],
      true,
    );

    const webBucket = new s3.Bucket(this, "WebBucket", {
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      encryption: s3.BucketEncryption.S3_MANAGED,
      enforceSSL: true,
      versioned: false,
      autoDeleteObjects: !isProduction,
      removalPolicy,
    });
    NagSuppressions.addResourceSuppressions(
      webBucket,
      [
        {
          id: "AwsSolutions-S1",
          reason:
            "The bucket is a private OAC origin. S3 access logs are intentionally disabled to prevent opaque pairing paths from entering a second persistent log store.",
        },
      ],
      true,
    );
    const responseHeaders = new cloudfront.ResponseHeadersPolicy(this, "SecurityHeaders", {
      responseHeadersPolicyName: `TerminalDBRemote-${props.stage}-Security`,
      securityHeadersBehavior: {
        contentSecurityPolicy: {
          override: true,
          contentSecurityPolicy:
            `default-src 'self'; connect-src 'self' ${cognitoDomainUrl} https://cognito-idp.${this.region}.${this.urlSuffix} wss:; font-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'`,
        },
        contentTypeOptions: { override: true },
        frameOptions: { frameOption: cloudfront.HeadersFrameOption.DENY, override: true },
        referrerPolicy: {
          referrerPolicy: cloudfront.HeadersReferrerPolicy.NO_REFERRER,
          override: true,
        },
        strictTransportSecurity: {
          accessControlMaxAge: Duration.days(730),
          includeSubdomains: true,
          preload: true,
          override: true,
        },
        xssProtection: { protection: true, modeBlock: true, override: true },
      },
      customHeadersBehavior: {
        customHeaders: [
          { header: "Permissions-Policy", value: "camera=(), microphone=(), geolocation=(), payment=()", override: true },
          { header: "Cross-Origin-Opener-Policy", value: "same-origin", override: true },
        ],
      },
    });
    const socketRewrite = new cloudfront.Function(this, "SocketRewrite", {
      code: cloudfront.FunctionCode.fromInline(
        `function handler(event){var r=event.request;r.uri=r.uri.replace(/^\\/socket(?:\\/.*)?$/,'/${webSocketStage.stageName}');return r;}`,
      ),
      runtime: cloudfront.FunctionRuntime.JS_2_0,
    });
    const spaRewrite = new cloudfront.Function(this, "SpaRewrite", {
      code: cloudfront.FunctionCode.fromInline(
        "function handler(event){var r=event.request;if(r.uri==='/'||!r.uri.split('/').pop().includes('.'))r.uri='/index.html';return r;}",
      ),
      runtime: cloudfront.FunctionRuntime.JS_2_0,
    });
    const apiDomain = `${httpApi.apiId}.execute-api.${this.region}.${this.urlSuffix}`;
    const socketDomain = `${webSocketApi.apiId}.execute-api.${this.region}.${this.urlSuffix}`;
    const distribution = new cloudfront.Distribution(this, "Distribution", {
      comment: `TerminalDB Remote ${props.stage}`,
      defaultRootObject: "index.html",
      webAclId: props.webAclArn,
      domainNames: props.domainName ? [props.domainName] : undefined,
      certificate: props.certificateArn
        ? acm.Certificate.fromCertificateArn(this, "ViewerCertificate", props.certificateArn)
        : undefined,
      minimumProtocolVersion: cloudfront.SecurityPolicyProtocol.TLS_V1_2_2021,
      httpVersion: cloudfront.HttpVersion.HTTP2_AND_3,
      priceClass: cloudfront.PriceClass.PRICE_CLASS_100,
      defaultBehavior: {
        origin: cloudfrontOrigins.S3BucketOrigin.withOriginAccessControl(webBucket),
        viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
        responseHeadersPolicy: responseHeaders,
        compress: true,
        functionAssociations: [
          {
            function: spaRewrite,
            eventType: cloudfront.FunctionEventType.VIEWER_REQUEST,
          },
        ],
      },
      additionalBehaviors: {
        "/api/*": {
          origin: new cloudfrontOrigins.HttpOrigin(apiDomain, {
            protocolPolicy: cloudfront.OriginProtocolPolicy.HTTPS_ONLY,
          }),
          viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.HTTPS_ONLY,
          allowedMethods: cloudfront.AllowedMethods.ALLOW_ALL,
          cachedMethods: cloudfront.CachedMethods.CACHE_GET_HEAD_OPTIONS,
          cachePolicy: cloudfront.CachePolicy.CACHING_DISABLED,
          originRequestPolicy: cloudfront.OriginRequestPolicy.ALL_VIEWER_EXCEPT_HOST_HEADER,
          responseHeadersPolicy: responseHeaders,
          compress: true,
        },
        "/socket*": {
          origin: new cloudfrontOrigins.HttpOrigin(socketDomain, {
            protocolPolicy: cloudfront.OriginProtocolPolicy.HTTPS_ONLY,
            readTimeout: Duration.seconds(60),
            keepaliveTimeout: Duration.seconds(60),
          }),
          viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.HTTPS_ONLY,
          allowedMethods: cloudfront.AllowedMethods.ALLOW_ALL,
          cachePolicy: cloudfront.CachePolicy.CACHING_DISABLED,
          originRequestPolicy: cloudfront.OriginRequestPolicy.ALL_VIEWER_EXCEPT_HOST_HEADER,
          responseHeadersPolicy: responseHeaders,
          functionAssociations: [
            {
              function: socketRewrite,
              eventType: cloudfront.FunctionEventType.VIEWER_REQUEST,
            },
          ],
        },
      },
    });
    controlFunction.addEnvironment(
      "PUBLIC_WEBSOCKET_URL",
      `wss://${props.domainName ?? distribution.distributionDomainName}/socket`,
    );
    const applicationOrigin = `https://${props.domainName ?? distribution.distributionDomainName}`;
    const userPoolClient = userPool.addClient("WebClientV2", {
      userPoolClientName: `terminaldb-remote-${props.stage}-web`,
      generateSecret: false,
      preventUserExistenceErrors: true,
      enableTokenRevocation: true,
      accessTokenValidity: Duration.hours(1),
      idTokenValidity: Duration.hours(1),
      refreshTokenValidity: Duration.days(30),
      authFlows: {
        user: true,
        userSrp: true,
      },
      supportedIdentityProviders: [
        cognito.UserPoolClientIdentityProvider.COGNITO,
      ],
      oAuth: {
        flows: {
          authorizationCodeGrant: true,
          implicitCodeGrant: false,
        },
        scopes: [
          cognito.OAuthScope.OPENID,
          cognito.OAuthScope.PROFILE,
          cognito.OAuthScope.COGNITO_ADMIN,
        ],
        callbackUrls: [`${applicationOrigin}/auth/callback`],
        logoutUrls: [applicationOrigin],
      },
    });
    userPool.addTrigger(cognito.UserPoolOperation.PRE_SIGN_UP, preSignupFunction);
    const managedLoginBranding = new cognito.CfnManagedLoginBranding(
      this,
      "ManagedLoginBranding",
      {
        userPoolId: userPool.userPoolId,
        clientId: userPoolClient.userPoolClientId,
        assets: terminalDBManagedLoginAssets,
        settings: terminalDBManagedLoginSettings,
      },
    );
    const userPoolDomainResource = userPoolDomain.node.defaultChild;
    if (!(userPoolDomainResource instanceof cognito.CfnUserPoolDomain)) {
      throw new Error("Expected a Cognito user-pool domain resource");
    }
    managedLoginBranding.addResourceDependency(userPoolDomainResource);
    const accountAuthorizer = new apigatewayv2Authorizers.HttpJwtAuthorizer(
      "AccountAuthorizer",
      userPool.userPoolProviderUrl,
      { jwtAudience: [userPoolClient.userPoolClientId] },
    );
    httpApi.addRoutes({
      path: "/api/v1/account/{proxy+}",
      methods: [apigatewayv2.HttpMethod.ANY],
      integration: httpIntegration,
      authorizer: accountAuthorizer,
      authorizationScopes: ["openid", "aws.cognito.signin.user.admin"],
    });
    httpApi.addRoutes({
      path: "/api/v1/account",
      methods: [apigatewayv2.HttpMethod.DELETE],
      integration: httpIntegration,
      authorizer: accountAuthorizer,
      authorizationScopes: ["openid", "aws.cognito.signin.user.admin"],
    });
    controlFunction.addEnvironment("COGNITO_AUTH_ENABLED", "true");
    controlFunction.addEnvironment("COGNITO_CLIENT_ID", userPoolClient.userPoolClientId);
    controlFunction.addEnvironment("COGNITO_DOMAIN", cognitoDomainUrl);
    controlFunction.addEnvironment("COGNITO_ISSUER", userPool.userPoolProviderUrl);
    controlFunction.addEnvironment("COGNITO_USER_POOL_ID", userPool.userPoolId);
    controlFunction.addToRolePolicy(new iam.PolicyStatement({
      actions: [
        "cognito-idp:AdminDeleteUser",
        "cognito-idp:AdminUserGlobalSignOut",
      ],
      resources: [userPool.userPoolArn],
    }));
    NagSuppressions.addResourceSuppressions(
      distribution,
      [
        {
          id: "AwsSolutions-CFR1",
          reason:
            "Remote controllers must continue working while the owner travels; identity and ticket controls provide access restriction instead of geography.",
        },
        {
          id: "AwsSolutions-CFR3",
          reason:
            "Viewer logging is disabled because pairing IDs are path components and must not be retained. API access logs deliberately omit query strings and payloads.",
        },
        {
          id: "AwsSolutions-CFR4",
          reason:
            "The dev distribution may use the CloudFront default certificate. Production requires a supplied ACM certificate and sets TLSv1.2_2021.",
        },
      ],
      true,
    );
    const webDeployment = new s3deploy.BucketDeployment(this, "DeployWeb", {
      destinationBucket: webBucket,
      distribution,
      distributionPaths: ["/*"],
      sources: [s3deploy.Source.asset(path.join(process.cwd(), "../../apps/web/dist"))],
      prune: true,
    });
    NagSuppressions.addResourceSuppressions(
      webDeployment,
      [
        {
          id: "AwsSolutions-IAM4",
          reason:
            "The CDK BucketDeployment singleton provider uses the CDK-managed basic execution policy and contains no application credentials.",
        },
        {
          id: "AwsSolutions-IAM5",
          reason:
            "Static deployment requires object-prefix permissions in the CDK asset bucket and the dedicated private web bucket.",
        },
        {
          id: "AwsSolutions-L1",
          reason:
            "The BucketDeployment runtime is owned and upgraded by the pinned AWS CDK library, not application code.",
        },
      ],
      true,
    );
    const deploymentProvider = this.node.tryFindChild(
      "Custom::CDKBucketDeployment8693BB64968944B69AAFB0CC9EB8756C",
    );
    if (deploymentProvider) {
      NagSuppressions.addResourceSuppressions(
        deploymentProvider,
        [
          {
            id: "AwsSolutions-IAM4",
            reason:
              "The singleton BucketDeployment provider is generated by the pinned AWS CDK library and only moves this build's static assets.",
          },
          {
            id: "AwsSolutions-IAM5",
            reason:
              "The CDK asset and destination object prefixes require wildcard suffixes because hashed filenames are not known until bundling.",
          },
          {
            id: "AwsSolutions-L1",
            reason:
              "The singleton provider runtime is owned and upgraded by the pinned AWS CDK library.",
          },
        ],
        true,
      );
    }

    const alerts = new sns.Topic(this, "CostAndHealthAlerts", {
      displayName: `TerminalDB Remote ${props.stage} alerts`,
      enforceSSL: true,
    });
    alerts.addToResourcePolicy(
      new iam.PolicyStatement({
        principals: [new iam.ServicePrincipal("budgets.amazonaws.com")],
        actions: ["sns:Publish"],
        resources: [alerts.topicArn],
      }),
    );
    if (props.budgetEmail) {
      const emailSubscription = alerts.addSubscription(
        new subscriptions.EmailSubscription(props.budgetEmail),
      );
      const emailResource = emailSubscription.node.defaultChild;
      if (!(emailResource instanceof sns.CfnSubscription)) {
        throw new Error("Expected an SNS email subscription resource");
      }
      emailResource.overrideLogicalId("CostAndHealthAlertsEmailSubscription");
    }
    const createBudget = (name: string, amount: number): void => {
      new budgets.CfnBudget(this, name, {
        budget: {
          budgetName: `TerminalDBRemote-${props.stage}-${amount}USD`,
          budgetType: "COST",
          timeUnit: "MONTHLY",
          budgetLimit: { amount, unit: "USD" },
          costFilters: {
            Service: [
              "Amazon API Gateway",
              "AWS Lambda",
              "Amazon DynamoDB",
              "Amazon CloudFront",
              "Amazon Simple Storage Service",
              "AWS WAF",
            ],
          },
        },
        notificationsWithSubscribers: [
          {
            notification: {
              comparisonOperator: "GREATER_THAN",
              notificationType: "ACTUAL",
              threshold: 80,
              thresholdType: "PERCENTAGE",
            },
            subscribers: [{ subscriptionType: "SNS", address: alerts.topicArn }],
          },
        ],
      });
    };
    createBudget("WarningBudget", 5);
    createBudget("CriticalBudget", 15);

    const relayErrors = new cloudwatch.Alarm(this, "RelayErrors", {
      metric: relayFunction.metricErrors({ period: Duration.minutes(5) }),
      threshold: 1,
      evaluationPeriods: 1,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });
    const throttleAlarm = new cloudwatch.Alarm(this, "DynamoThrottles", {
      metric: table.metricSystemErrorsForOperations({
        operations: [dynamodb.Operation.GET_ITEM, dynamodb.Operation.PUT_ITEM],
        period: Duration.minutes(5),
      }),
      threshold: 1,
      evaluationPeriods: 1,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });
    relayErrors.addAlarmAction(new cloudwatchActions.SnsAction(alerts));
    throttleAlarm.addAlarmAction(new cloudwatchActions.SnsAction(alerts));

    new CfnOutput(this, "RemoteUrl", {
      value: props.domainName ? `https://${props.domainName}` : `https://${distribution.distributionDomainName}`,
    });
    new CfnOutput(this, "RemoteDistributionDomain", {
      value: distribution.distributionDomainName,
    });
    new CfnOutput(this, "CognitoDomain", { value: cognitoDomainUrl });
    if (props.authDomainName) {
      new CfnOutput(this, "CognitoDistributionDomain", {
        value: userPoolDomain.cloudFrontEndpoint,
      });
    }
    new CfnOutput(this, "ControlFunctionName", { value: controlFunction.functionName });
    new CfnOutput(this, "EnrollmentCommand", {
      value: `npm run remote:enrollment -- --profile stelao --function-name ${controlFunction.functionName}`,
    });
    new CfnOutput(this, "WebSocketApiId", { value: webSocketApi.apiId });
    new CfnOutput(this, "UserPoolId", { value: userPool.userPoolId });
    new CfnOutput(this, "UserPoolClientId", { value: userPoolClient.userPoolClientId });
    new CfnOutput(this, "CloudFrontPlan", {
      value:
        props.cloudfrontPlan === "FREE"
          ? "FREE requested: associate the distribution in the CloudFront console if this account is eligible"
          : "PAYG",
    });
    new CfnOutput(this, "AlertTopicArn", { value: alerts.topicArn });

    // Keep the explicitly-created stage alive even though route configuration owns the API deployment.
    httpStage.node.addDependency(httpApi);
  }
}
