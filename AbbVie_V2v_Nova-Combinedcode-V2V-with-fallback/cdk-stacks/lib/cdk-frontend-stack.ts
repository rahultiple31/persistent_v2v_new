// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import * as cdk from "aws-cdk-lib";
import { Construct } from "constructs";
import * as s3 from "aws-cdk-lib/aws-s3";
import * as ssm from "aws-cdk-lib/aws-ssm";
import * as cloudfront from "aws-cdk-lib/aws-cloudfront";
import * as origins from "aws-cdk-lib/aws-cloudfront-origins";
import * as cr from "aws-cdk-lib/custom-resources";
import { FrontendS3DeploymentStack } from "../lib/frontend/frontend-s3-deployment-stack";
import { FrontendConfigStack } from "./frontend/frontend-config-stack";
import { ProxyStack } from "./proxy/proxy-stack";
import { loadSSMParams, optionalParamDefault, ssmParameterHierarchy, translationMode } from "../config/ssm-params-util";

const configParams = require("../config/config.params.json");

/**
 * Content Security Policy for the webapp:
 *  - scripts, styles, fonts and images only from the app's own origin (no inline scripts);
 *  - network connections only to the app itself (including the proxy at /ws and /api), the Cognito
 *    domain, the Amazon Connect instance and Connect's softphone signalling; plus AWS endpoints in
 *    direct mode, where the browser calls AWS itself;
 *  - frames only from the Connect instance (the CCP), and the app itself cannot be framed.
 * If a stolen or injected script runs anyway, it cannot send tokens or call data to any other site.
 */
function contentSecurityPolicy(ssmParams: any, region: string, enforced: boolean): string {
  const originOf = (url: string): string | undefined => {
    try {
      return new URL(url).origin;
    } catch {
      return undefined; // placeholder value during the first CDK synth pass
    }
  };
  const cognito = `https://${ssmParams.cognitoDomainPrefix}.auth.${region}.amazoncognito.com`;
  const connect = originOf(ssmParams.connectInstanceURL);
  const connectSignalling = `wss://*.connect-telecom.${ssmParams.connectInstanceRegion}.amazonaws.com`;
  const directModeAws = translationMode(ssmParams) === "direct" ? ["https://*.amazonaws.com", "wss://*.amazonaws.com:8443"] : [];
  const directives = [
    "default-src 'self'",
    "script-src 'self'",
    // Inline style attributes in index.html, and styles set by Bootstrap and the CCP library.
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data: blob:",
    "font-src 'self' data:",
    "media-src 'self' blob: data:",
    `connect-src 'self' ${[cognito, connect, connectSignalling, ...directModeAws].filter(Boolean).join(" ")}`,
    `frame-src ${connect ?? "'none'"}`,
    "worker-src 'self' blob:",
    "object-src 'none'",
    "base-uri 'self'",
    "form-action 'self'",
    "frame-ancestors 'none'",
    ...(enforced ? ["upgrade-insecure-requests"] : []),
  ];
  return directives.join("; ");
}

export interface CdkFrontendStackProps extends cdk.StackProps {
  readonly backendStackOutputs: { key: string; value: string }[];
  readonly userPoolId: string;
  readonly userPoolClientId: string;
}

export class CdkFrontendStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: CdkFrontendStackProps) {
    super(scope, id, props);

    //store physical stack name to SSM
    const outputHierarchy = `${ssmParameterHierarchy()}outputParameters`;
    const cdkFrontendStackName = new ssm.StringParameter(this, "CdkFrontendStackName", {
      parameterName: `${outputHierarchy}/CdkFrontendStackName`,
      stringValue: this.stackName,
    });

    // Create each optional parameter from config.params.json that doesn't exist yet, with its default value,
    // so a new environment needs no manual step for them. An existing parameter is never overwritten (its
    // value stays the switch), and the parameters are kept if this stack is deleted.
    for (const param of configParams.parameters.filter((p: any) => !p.required)) {
      const parameterName = `${ssmParameterHierarchy()}${param.name}`;
      new cr.AwsCustomResource(this, `CreateSsmParameter-${param.name}`, {
        onCreate: {
          service: "SSM",
          action: "PutParameter",
          parameters: { Name: parameterName, Value: optionalParamDefault(param), Type: "String", Overwrite: false },
          physicalResourceId: cr.PhysicalResourceId.of(parameterName),
          ignoreErrorCodesMatching: "ParameterAlreadyExists",
        },
        policy: cr.AwsCustomResourcePolicy.fromSdkCalls({
          resources: [`arn:aws:ssm:${this.region}:${this.account}:parameter${parameterName}`],
        }),
        installLatestAwsSdk: false,
      });
    }

    //create webapp bucket
    const webAppBucket = new s3.Bucket(this, "WebAppBucket", {
      bucketName: `${configParams["CdkAppName"]}-WebAppBucket-${this.region}`.toLowerCase(),
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      encryption: s3.BucketEncryption.S3_MANAGED,
      enforceSSL: true,
      versioned: true,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    const webAppLogBucket = new s3.Bucket(this, "WebAppLogBucket", {
      bucketName: `${configParams["CdkAppName"]}-WebAppLogBucket-${this.region}`.toLowerCase(),
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      encryption: s3.BucketEncryption.S3_MANAGED,
      enforceSSL: true,
      versioned: true,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      objectOwnership: s3.ObjectOwnership.OBJECT_WRITER,
      accessControl: s3.BucketAccessControl.LOG_DELIVERY_WRITE,
    });

    const frontendS3DeploymentStack = new FrontendS3DeploymentStack(this, "FrontendS3DeploymentStack", {
      cdkAppName: configParams["CdkAppName"],
      webAppBucket: webAppBucket,
    });

    // Server-side proxy (proxyEnabled): served from this distribution at /ws (WebSocket) and /api/*, so
    // the webapp reaches it on its own origin - no CORS, and one TLS endpoint for everything.
    // Not deployed while translation is off (translationEnabled=false), whatever proxyEnabled says.
    const ssmParams = loadSSMParams(this);
    const proxyBehaviors: Record<string, cloudfront.BehaviorOptions> = {};
    if (translationMode(ssmParams) === "proxy") {
      const proxyStack = new ProxyStack(this, "ProxyStack", {
        cdkAppName: configParams["CdkAppName"],
        ssmParams,
        userPoolId: props.userPoolId,
        userPoolClientId: props.userPoolClientId,
      });
      const proxyOrigin = origins.VpcOrigin.withApplicationLoadBalancer(proxyStack.loadBalancer, {
        vpcOriginName: `${configParams["CdkAppName"]}-proxy`,
        protocolPolicy: cloudfront.OriginProtocolPolicy.HTTP_ONLY,
        httpPort: 80,
        // The proxy pings every WebSocket every 25 s, inside CloudFront's 30 s origin read timeout.
        readTimeout: cdk.Duration.seconds(30),
        keepaliveTimeout: cdk.Duration.seconds(60),
      });
      const proxyBehavior: cloudfront.BehaviorOptions = {
        origin: proxyOrigin,
        viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.HTTPS_ONLY,
        cachePolicy: cloudfront.CachePolicy.CACHING_DISABLED,
        // Forwards Authorization, Origin and the Sec-WebSocket-* handshake headers.
        originRequestPolicy: cloudfront.OriginRequestPolicy.ALL_VIEWER_EXCEPT_HOST_HEADER,
        compress: false,
      };
      proxyBehaviors["/ws"] = { ...proxyBehavior, allowedMethods: cloudfront.AllowedMethods.ALLOW_GET_HEAD };
      proxyBehaviors["/api/*"] = { ...proxyBehavior, allowedMethods: cloudfront.AllowedMethods.ALLOW_ALL };
    }

    // Security headers for the webapp. The Content Security Policy is report-only until cspEnforced is true:
    // the browser console then lists anything the policy would block, without blocking it.
    const csp = (enforced: boolean) => contentSecurityPolicy(ssmParams, this.region, enforced);
    const securityHeadersPolicy = new cloudfront.ResponseHeadersPolicy(this, "WebAppSecurityHeaders", {
      comment: `Security headers for ${configParams["CdkAppName"]}`,
      securityHeadersBehavior: {
        strictTransportSecurity: { accessControlMaxAge: cdk.Duration.days(365), includeSubdomains: true, override: true },
        contentTypeOptions: { override: true },
        frameOptions: { frameOption: cloudfront.HeadersFrameOption.DENY, override: true },
        referrerPolicy: { referrerPolicy: cloudfront.HeadersReferrerPolicy.STRICT_ORIGIN_WHEN_CROSS_ORIGIN, override: true },
        ...(ssmParams.cspEnforced ? { contentSecurityPolicy: { contentSecurityPolicy: csp(true), override: true } } : {}),
      },
      ...(ssmParams.cspEnforced
        ? {}
        : { customHeadersBehavior: { customHeaders: [{ header: "Content-Security-Policy-Report-Only", value: csp(false), override: true }] } }),
    });

    const webAppCloudFrontDistribution = new cloudfront.Distribution(this, `${configParams["CdkAppName"]}-WebAppDistribution`, {
      comment: `CloudFront for ${configParams["CdkAppName"]}`,
      enableIpv6: false,
      enableLogging: true,
      logBucket: webAppLogBucket,
      logIncludesCookies: false,
      logFilePrefix: "cloudfront-logs/",
      defaultBehavior: {
        origin: origins.S3BucketOrigin.withOriginAccessControl(webAppBucket, {
          originPath: `/${configParams["WebAppRootPrefix"].replace(/\/$/, "")}`,
        }),
        allowedMethods: cloudfront.AllowedMethods.ALLOW_GET_HEAD_OPTIONS,
        viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
        compress: true,
        cachePolicy: cloudfront.CachePolicy.CACHING_DISABLED,
        responseHeadersPolicy: securityHeadersPolicy,
      },
      additionalBehaviors: proxyBehaviors,
      // Applies to every behavior, which is why the proxy answers auth failures with 401, never 403.
      errorResponses: [
        {
          httpStatus: 403,
          responseHttpStatus: 200,
          responsePagePath: "/index.html",
          ttl: cdk.Duration.seconds(60),
        },
      ],
    });

    //create frontend config
    const frontendConfigStack = new FrontendConfigStack(this, "FrontendConfigStack", {
      cdkAppName: configParams["CdkAppName"],
      webAppBucket: webAppBucket,
      backendStackOutputs: props.backendStackOutputs,
    });
    // Both write frontend-config.js. The webapp copy waits for the settings to be written, so a deploy can
    // never finish with the previous settings in it.
    frontendS3DeploymentStack.webAppDeployment.node.addDependency(frontendConfigStack);

    /**************************************************************************************************************
     * CDK Outputs *
     **************************************************************************************************************/

    new cdk.CfnOutput(this, "webAppBucket", {
      value: webAppBucket.bucketName,
    });

    new cdk.CfnOutput(this, "webAppURL", {
      value: `https://${webAppCloudFrontDistribution.distributionDomainName}`,
    });
  }
}