import { CfnOutput, Stack, type StackProps } from "aws-cdk-lib";
import * as wafv2 from "aws-cdk-lib/aws-wafv2";
import type { Construct } from "constructs";

export class TerminalDBRemoteEdgeStack extends Stack {
  readonly webAclArn: string;

  constructor(scope: Construct, id: string, props?: StackProps) {
    super(scope, id, props);

    const visibility = (metricName: string): wafv2.CfnWebACL.VisibilityConfigProperty => ({
      cloudWatchMetricsEnabled: true,
      metricName,
      sampledRequestsEnabled: false,
    });
    const webAcl = new wafv2.CfnWebACL(this, "RemoteWebAcl", {
      scope: "CLOUDFRONT",
      defaultAction: { allow: {} },
      description: "Five-rule personal-use protection for TerminalDB Remote",
      visibilityConfig: visibility("TerminalDBRemoteWebAcl"),
      rules: [
        {
          name: "AWSManagedCore",
          priority: 0,
          overrideAction: { none: {} },
          statement: {
            managedRuleGroupStatement: {
              vendorName: "AWS",
              name: "AWSManagedRulesCommonRuleSet",
            },
          },
          visibilityConfig: visibility("TerminalDBRemoteCore"),
        },
        {
          name: "AWSKnownBadInputs",
          priority: 1,
          overrideAction: { none: {} },
          statement: {
            managedRuleGroupStatement: {
              vendorName: "AWS",
              name: "AWSManagedRulesKnownBadInputsRuleSet",
            },
          },
          visibilityConfig: visibility("TerminalDBRemoteBadInputs"),
        },
        {
          name: "AWSIpReputation",
          priority: 2,
          overrideAction: { none: {} },
          statement: {
            managedRuleGroupStatement: {
              vendorName: "AWS",
              name: "AWSManagedRulesAmazonIpReputationList",
            },
          },
          visibilityConfig: visibility("TerminalDBRemoteIpReputation"),
        },
        {
          name: "PairingAndApiRate",
          priority: 3,
          action: { block: {} },
          statement: {
            rateBasedStatement: {
              aggregateKeyType: "IP",
              limit: 100,
              evaluationWindowSec: 60,
              scopeDownStatement: {
                byteMatchStatement: {
                  fieldToMatch: { uriPath: {} },
                  positionalConstraint: "STARTS_WITH",
                  searchString: "/api/",
                  textTransformations: [{ priority: 0, type: "NONE" }],
                },
              },
            },
          },
          visibilityConfig: visibility("TerminalDBRemoteApiRate"),
        },
        {
          name: "SocketUpgradeRate",
          priority: 4,
          action: { block: {} },
          statement: {
            rateBasedStatement: {
              aggregateKeyType: "IP",
              limit: 100,
              evaluationWindowSec: 60,
              scopeDownStatement: {
                byteMatchStatement: {
                  fieldToMatch: { uriPath: {} },
                  positionalConstraint: "STARTS_WITH",
                  searchString: "/socket",
                  textTransformations: [{ priority: 0, type: "NONE" }],
                },
              },
            },
          },
          visibilityConfig: visibility("TerminalDBRemoteSocketRate"),
        },
      ],
    });
    this.webAclArn = webAcl.attrArn;
    new CfnOutput(this, "WebAclArn", { value: this.webAclArn });
  }
}
