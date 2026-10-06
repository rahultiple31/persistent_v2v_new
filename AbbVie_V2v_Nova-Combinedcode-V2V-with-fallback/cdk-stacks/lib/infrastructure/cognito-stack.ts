// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import * as cdk from "aws-cdk-lib";
import * as iam from "aws-cdk-lib/aws-iam";
import * as cognito from "aws-cdk-lib/aws-cognito";
import { Construct } from "constructs";
import { serviceRegion, translationMode } from "../../config/ssm-params-util";

/** How long a sign-in lasts before the agent must sign in again (refresh token lifetime). */
export const REFRESH_TOKEN_VALIDITY = cdk.Duration.hours(12);

/** How long each access and ID token lasts. The webapp renews both in the background 4 minutes before they expire. */
export const TOKEN_VALIDITY = cdk.Duration.minutes(20);

export interface CognitoStackProps extends cdk.NestedStackProps {
  readonly SSMParams: any;
  readonly cdkAppName: string;
}

export class CognitoStack extends cdk.NestedStack {
  public readonly authenticatedRole: iam.IRole;

  public readonly identityPool: cognito.CfnIdentityPool;
  public readonly userPool: cognito.IUserPool;
  public readonly userPoolClient: cognito.IUserPoolClient;
  public readonly userPoolDomain: cognito.CfnUserPoolDomain;

  constructor(scope: Construct, id: string, props: CognitoStackProps) {
    super(scope, id, props);

    //create a User Pool
    const userPool = new cognito.UserPool(this, "UserPool", {
      userPoolName: `${props.cdkAppName}-UserPool`,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      signInAliases: {
        username: false,
        phone: false,
        email: true,
      },
      standardAttributes: {
        email: {
          required: false, //Cognito bug with federation - If you make a user pool with required email field then the second login attempt fails (https://github.com/aws-amplify/amplify-js/issues/3526)
          mutable: true,
        },
      },
      customAttributes: {
        connectUserId: new cognito.StringAttribute({ minLen: 36, maxLen: 36, mutable: true }),
      },
      userInvitation: {
        emailSubject: `Your ${props.SSMParams.CdkAppName} temporary password`,
        emailBody: `Your ${props.SSMParams.CdkAppName} username is {username} and temporary password is {####}`,
      },
      userVerification: {
        emailSubject: `Verify your new ${props.SSMParams.CdkAppName} account`,
        emailBody: `The verification code to your new ${props.SSMParams.CdkAppName} account is {####}`,
      },
    });

    //SAML Federation
    let supportedIdentityProviders: cognito.UserPoolClientIdentityProvider[] = [];
    let userPoolClientOAuthConfig: cognito.OAuthSettings = {
      scopes: [cognito.OAuthScope.EMAIL, cognito.OAuthScope.OPENID, cognito.OAuthScope.COGNITO_ADMIN, cognito.OAuthScope.PROFILE],
    };

    // Sign-in options offered by the app client. With SSO enabled, only the corporate identity provider:
    // password sign-in on the Cognito page is off. The provider itself is created in the Cognito console;
    // naming it here keeps it on the app client when a deploy updates the client, instead of the list
    // being reset to COGNITO (which would turn password sign-in back on and break SSO).
    if (props.SSMParams.ssoEnabled) {
      supportedIdentityProviders.push(cognito.UserPoolClientIdentityProvider.custom(props.SSMParams.ssoProviderName));
    } else {
      supportedIdentityProviders.push(cognito.UserPoolClientIdentityProvider.COGNITO);
    }

    //create a User Pool Client
    const userPoolClient = new cognito.UserPoolClient(this, "UserPoolClient", {
      userPool: userPool,
      userPoolClientName: props.SSMParams.CdkFrontendStack,
      generateSecret: false,
      supportedIdentityProviders: supportedIdentityProviders,
      // One working shift. The webapp warns the agent 30 minutes before, and never signs out during a call.
      refreshTokenValidity: REFRESH_TOKEN_VALIDITY,
      // Short-lived, so a copied token soon stops working, including at the proxy, which checks tokens itself
      // and does not see a sign-out.
      accessTokenValidity: TOKEN_VALIDITY,
      idTokenValidity: TOKEN_VALIDITY,
      // Lets the webapp revoke the refresh token at sign-out (/oauth2/revoke).
      enableTokenRevocation: true,
      oAuth: {
        ...userPoolClientOAuthConfig,
        callbackUrls: props.SSMParams.cognitoCallbackUrls.split(",").map((item: string) => item.trim()),
        logoutUrls: props.SSMParams.cognitoLogoutUrls.split(",").map((item: string) => item.trim()),
      },
    });

    const userPoolDomain = new cognito.CfnUserPoolDomain(this, "UserPoolDomain", {
      domain: props.SSMParams.cognitoDomainPrefix,
      userPoolId: userPool.userPoolId,
    });

    //create an Identity Pool
    const identityPool = new cognito.CfnIdentityPool(this, "IdentityPool", {
      identityPoolName: `${props.cdkAppName}-IdentityPool`,
      allowUnauthenticatedIdentities: false,
      cognitoIdentityProviders: [
        {
          clientId: userPoolClient.userPoolClientId,
          providerName: userPool.userPoolProviderName,
        },
      ],
    });

    //Cognito Identity Pool Roles
    const unauthenticatedRole = new iam.Role(this, "CognitoDefaultUnauthenticatedRole", {
      assumedBy: new iam.FederatedPrincipal(
        "cognito-identity.amazonaws.com",
        {
          StringEquals: { "cognito-identity.amazonaws.com:aud": identityPool.ref },
          "ForAnyValue:StringLike": { "cognito-identity.amazonaws.com:amr": "unauthenticated" },
        },
        "sts:AssumeRoleWithWebIdentity"
      ),
    });

    // Unauthenticated identities are disabled on the pool; the role exists only because the role
    // attachment requires one, and it has no permissions.

    const authenticatedRole = new iam.Role(this, "CognitoDefaultAuthenticatedRole", {
      assumedBy: new iam.FederatedPrincipal(
        "cognito-identity.amazonaws.com",
        {
          StringEquals: { "cognito-identity.amazonaws.com:aud": identityPool.ref },
          "ForAnyValue:StringLike": { "cognito-identity.amazonaws.com:amr": "authenticated" },
        },
        "sts:AssumeRoleWithWebIdentity"
      ),
    });

    // Direct mode (proxyEnabled=false): the browser calls AWS with these credentials, so they get exactly
    // the four calls the webapp makes, limited to the configured model and Regions. The identity-pool
    // calls themselves (GetId, GetCredentialsForIdentity) need no IAM permission.
    //
    // Proxy mode: the proxy's task role makes those calls instead and the browser never requests
    // credentials, so this role gets no permissions at all.
    //
    // Translation off (translationEnabled=false): no permissions either. Greying out the panels is not a
    // control on its own; without these permissions no translation call can succeed from the browser.
    if (translationMode(props.SSMParams) === "direct") {
      const inRegion = (paramName: string) => ({
        StringEquals: { "aws:RequestedRegion": serviceRegion(props.SSMParams, paramName) },
      });
      authenticatedRole.addToPolicy(
        new iam.PolicyStatement({
          actions: ["bedrock:InvokeModel"], // the IAM action for InvokeModelWithBidirectionalStream
          resources: [
            `arn:${cdk.Aws.PARTITION}:bedrock:${props.SSMParams.bedrockRegion}::foundation-model/${props.SSMParams.novaSonicModelId}`,
          ],
        })
      );
      // These actions do not support resource-level permissions, hence "*" with a Region condition.
      authenticatedRole.addToPolicy(
        new iam.PolicyStatement({ actions: ["transcribe:StartStreamTranscription"], resources: ["*"], conditions: inRegion("transcribeRegion") })
      );
      // Translate + Polly back the fallback path (translateFallbackAdapter.js); without them every
      // drift/refusal turn leaves the customer in silence.
      authenticatedRole.addToPolicy(
        new iam.PolicyStatement({ actions: ["translate:TranslateText"], resources: ["*"], conditions: inRegion("translateRegion") })
      );
      authenticatedRole.addToPolicy(
        new iam.PolicyStatement({ actions: ["polly:SynthesizeSpeech"], resources: ["*"], conditions: inRegion("pollyRegion") })
      );
    }

    const defaultPolicy = new cognito.CfnIdentityPoolRoleAttachment(this, "DefaultValid", {
      identityPoolId: identityPool.ref,
      roles: {
        unauthenticated: unauthenticatedRole.roleArn,
        authenticated: authenticatedRole.roleArn,
      },
    });

    this.authenticatedRole = authenticatedRole;

    /**************************************************************************************************************
     * Stack Outputs *
     **************************************************************************************************************/

    this.identityPool = identityPool;
    this.userPool = userPool;
    this.userPoolClient = userPoolClient;
    this.userPoolDomain = userPoolDomain;
  }
}
