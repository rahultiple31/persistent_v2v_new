// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import * as cdk from "aws-cdk-lib";
import { Construct } from "constructs";
import * as ssm from "aws-cdk-lib/aws-ssm";

import { loadSSMParams, serviceRegion, ssmParameterHierarchy, translationMode } from "../config/ssm-params-util";
const configParams = require("../config/config.params.json");

import { CognitoStack, REFRESH_TOKEN_VALIDITY } from "./infrastructure/cognito-stack";
import { FrontendConfigStack } from "./frontend/frontend-config-stack";

export class CdkBackendStack extends cdk.Stack {
  public readonly backendStackOutputs: { key: string; value: string }[];
  public readonly userPoolId: string;
  public readonly userPoolClientId: string;

  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);
    this.backendStackOutputs = [];

    //store physical stack name to SSM
    const outputHierarchy = `${ssmParameterHierarchy()}outputParameters`;
    const cdkBackendStackName = new ssm.StringParameter(this, "CdkBackendStackName", {
      parameterName: `${outputHierarchy}/CdkBackendStackName`,
      stringValue: this.stackName,
    });

    const ssmParams = loadSSMParams(this);

    const cognitoStack = new CognitoStack(this, "CognitoStack", {
      SSMParams: ssmParams,
      cdkAppName: configParams["CdkAppName"],
    });
    this.userPoolId = cognitoStack.userPool.userPoolId;
    this.userPoolClientId = cognitoStack.userPoolClient.userPoolClientId;

    /**************************************************************************************************************
     * CDK Outputs *
     **************************************************************************************************************/
    this.backendStackOutputs.push({ key: "backendRegion", value: this.region });
    this.backendStackOutputs.push({ key: "identityPoolId", value: cognitoStack.identityPool.ref });
    this.backendStackOutputs.push({ key: "userPoolId", value: cognitoStack.userPool.userPoolId });
    this.backendStackOutputs.push({ key: "userPoolWebClientId", value: cognitoStack.userPoolClient.userPoolClientId });
    this.backendStackOutputs.push({ key: "cognitoDomainURL", value: `https://${cognitoStack.userPoolDomain.domain}.auth.${this.region}.amazoncognito.com` });
    this.backendStackOutputs.push({ key: "connectInstanceURL", value: ssmParams.connectInstanceURL });
    this.backendStackOutputs.push({ key: "connectInstanceRegion", value: ssmParams.connectInstanceRegion });
    this.backendStackOutputs.push({ key: "bedrockRegion", value: ssmParams.bedrockRegion });
    this.backendStackOutputs.push({ key: "novaSonicModelId", value: ssmParams.novaSonicModelId });
    // Transcribe, Translate and Polly each have their own Region parameter; any left not-defined
    // follows bedrockRegion, so single-region deployments need no extra settings.
    this.backendStackOutputs.push({ key: "transcribeRegion", value: serviceRegion(ssmParams, "transcribeRegion") });
    this.backendStackOutputs.push({ key: "translateRegion", value: serviceRegion(ssmParams, "translateRegion") });
    this.backendStackOutputs.push({ key: "pollyRegion", value: serviceRegion(ssmParams, "pollyRegion") });
    // Translation switch for the webapp: false greys out the translation panels and the app is a plain softphone.
    this.backendStackOutputs.push({ key: "translationEnabled", value: String(translationMode(ssmParams) !== "off") });
    // Proxy switch for the webapp: when enabled, every AWS call goes through the server-side proxy. Never true
    // while translation is off, because the proxy is then not deployed.
    this.backendStackOutputs.push({ key: "proxyEnabled", value: String(translationMode(ssmParams) === "proxy") });
    // Lets the webapp warn the agent before their sign-in session ends.
    this.backendStackOutputs.push({ key: "refreshTokenValidityHours", value: String(REFRESH_TOKEN_VALIDITY.toHours()) });
    // SSO switch for the webapp: when enabled, sign-in goes straight to the SSO provider instead of the
    // Cognito sign-in page. The identity provider itself is configured in the Cognito console.
    this.backendStackOutputs.push({
      key: "ssoProviderName",
      value: ssmParams.ssoEnabled ? ssmParams.ssoProviderName : ssmParams.SSM_NOT_DEFINED,
    });

    new cdk.CfnOutput(this, "userPoolId", {
      value: cognitoStack.userPool.userPoolId,
    });
  }
}
