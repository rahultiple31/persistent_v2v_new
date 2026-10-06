// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import { Construct } from "constructs";
import * as cdk from "aws-cdk-lib";
import * as s3deployment from "aws-cdk-lib/aws-s3-deployment";
import * as s3 from "aws-cdk-lib/aws-s3";
 
const configParams = require("../../config/config.params.json");
 
export interface FrontendS3DeploymentStackProps extends cdk.NestedStackProps {
  readonly cdkAppName: string;
  readonly webAppBucket: s3.IBucket;
}
 
export class FrontendS3DeploymentStack extends cdk.NestedStack {
  public readonly webAppBucket: s3.IBucket;
  public readonly webAppDeployment: s3deployment.BucketDeployment;

  constructor(scope: Construct, id: string, props: FrontendS3DeploymentStackProps) {
    super(scope, id, props);

    this.webAppDeployment = new s3deployment.BucketDeployment(scope, `${props.cdkAppName}-WebAppDeployment`, {
      destinationBucket: props.webAppBucket,
      retainOnDelete: false,
      destinationKeyPrefix: configParams["WebAppRootPrefix"],
      // Browsers check with CloudFront on every page load, so a deploy (new code, or a setting such as
      // translationEnabled) reaches an agent at their next reload. A file that has not changed is not downloaded
      // again.
      cacheControl: [s3deployment.CacheControl.noCache()],
      // Keep the previous build's files. A page that is already open loads parts of the app later (the AWS SDK
      // clients and the audio worklets, under names that change with every build); deleting them would break
      // translation on that page until the agent reloads.
      prune: false,
      sources: [
        s3deployment.Source.asset("../webapp/dist"),
        s3deployment.Source.bucket(props.webAppBucket, `${configParams["WebAppStagingPrefix"]}frontend-config.zip`),
      ],
    });
  }
}
