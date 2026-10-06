// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import * as path from "path";
import * as cdk from "aws-cdk-lib";
import * as ec2 from "aws-cdk-lib/aws-ec2";
import * as ecs from "aws-cdk-lib/aws-ecs";
import * as elbv2 from "aws-cdk-lib/aws-elasticloadbalancingv2";
import * as iam from "aws-cdk-lib/aws-iam";
import * as logs from "aws-cdk-lib/aws-logs";
import * as s3 from "aws-cdk-lib/aws-s3";
import { Platform } from "aws-cdk-lib/aws-ecr-assets";
import { Construct } from "constructs";
import { optionalList, serviceRegion, ssmParameterHierarchy } from "../../config/ssm-params-util";

export interface ProxyStackProps extends cdk.NestedStackProps {
  readonly cdkAppName: string;
  readonly ssmParams: any;
  readonly userPoolId: string;
  readonly userPoolClientId: string;
}

const CONTAINER_PORT = 8080;
// Longer than a Nova Sonic session (8 min, restarted by the webapp at 7.5 min). During a deployment or
// scale-in, every in-flight session therefore reaches its natural restart, which lands on a healthy
// task, before the old task is stopped.
const DEREGISTRATION_DELAY = cdk.Duration.seconds(480);

/**
 * Server-side proxy: Nova Sonic, Transcribe, Translate and Polly are called from here with the task
 * role, so the browser never holds AWS credentials. It also reads the forceBackupTranslation switch.
 *
 *   browser --HTTPS/WSS--> CloudFront --VPC origin (AWS network)--> internal ALB --> Fargate tasks
 *
 * The load balancer is in private subnets with no public address; CloudFront is the only way in.
 */
export class ProxyStack extends cdk.NestedStack {
  public readonly loadBalancer: elbv2.ApplicationLoadBalancer;

  constructor(scope: Construct, id: string, props: ProxyStackProps) {
    super(scope, id, props);
    const { ssmParams } = props;

    const availabilityZones = optionalList(ssmParams, "proxyAvailabilityZones");
    if (availabilityZones.length !== 0 && availabilityZones.length !== 2) {
      throw new Error(`proxyAvailabilityZones must name exactly 2 Availability Zones, got: ${availabilityZones.join(", ")}`);
    }

    /**************************************************************************************************************
     * Network *
     **************************************************************************************************************/
    const flowLogGroup = new logs.LogGroup(this, "ProxyVpcFlowLogs", {
      retention: logs.RetentionDays.THREE_MONTHS,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    // The internet gateway (created with the public subnets) is required by CloudFront VPC origins;
    // the NAT gateway gives the tasks outbound access to the AWS APIs and the Cognito signing keys.
    const vpc = new ec2.Vpc(this, "ProxyVpc", {
      ...(availabilityZones.length ? { availabilityZones } : { maxAzs: 2 }),
      natGateways: 1,
      subnetConfiguration: [
        { name: "public", subnetType: ec2.SubnetType.PUBLIC, cidrMask: 24 },
        { name: "private", subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS, cidrMask: 22 },
      ],
      flowLogs: {
        all: { destination: ec2.FlowLogDestination.toCloudWatchLogs(flowLogGroup), trafficType: ec2.FlowLogTrafficType.ALL },
      },
    });
    // Free, and keeps container image layer downloads off the NAT gateway.
    vpc.addGatewayEndpoint("S3Endpoint", { service: ec2.GatewayVpcEndpointAwsService.S3 });

    const albSecurityGroup = new ec2.SecurityGroup(this, "ProxyAlbSecurityGroup", {
      vpc,
      description: "V2V proxy load balancer: HTTP from CloudFront only",
      allowAllOutbound: false,
    });
    const cloudFrontOriginFacing = ec2.PrefixList.fromLookup(this, "CloudFrontOriginFacing", {
      prefixListName: "com.amazonaws.global.cloudfront.origin-facing",
    });
    albSecurityGroup.addIngressRule(ec2.Peer.prefixList(cloudFrontOriginFacing.prefixListId), ec2.Port.tcp(80), "CloudFront VPC origin");

    const serviceSecurityGroup = new ec2.SecurityGroup(this, "ProxyServiceSecurityGroup", {
      vpc,
      description: "V2V proxy tasks: traffic from the load balancer only; HTTPS out to AWS APIs",
      allowAllOutbound: false,
    });
    serviceSecurityGroup.addEgressRule(ec2.Peer.anyIpv4(), ec2.Port.tcp(443), "HTTPS to AWS APIs and Cognito JWKS");

    /**************************************************************************************************************
     * Load balancer *
     **************************************************************************************************************/
    const albLogBucket = new s3.Bucket(this, "ProxyAlbLogBucket", {
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      encryption: s3.BucketEncryption.S3_MANAGED,
      enforceSSL: true,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
      lifecycleRules: [{ expiration: cdk.Duration.days(90) }],
    });

    this.loadBalancer = new elbv2.ApplicationLoadBalancer(this, "ProxyAlb", {
      vpc,
      internetFacing: false,
      vpcSubnets: { subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS },
      securityGroup: albSecurityGroup,
      // WebSockets carry a 25-second heartbeat, so 120 s only closes genuinely dead connections.
      idleTimeout: cdk.Duration.seconds(120),
      dropInvalidHeaderFields: true,
    });
    this.loadBalancer.logAccessLogs(albLogBucket, "proxy-alb");

    // HTTP between CloudFront and the load balancer: this hop runs over the VPC origin's private
    // connection inside the AWS network. HTTPS here would need a custom domain and certificate.
    const listener = this.loadBalancer.addListener("Http", { port: 80, protocol: elbv2.ApplicationProtocol.HTTP, open: false });

    /**************************************************************************************************************
     * Service *
     **************************************************************************************************************/
    const logGroup = new logs.LogGroup(this, "ProxyLogs", {
      retention: logs.RetentionDays.THREE_MONTHS,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    const taskDefinition = new ecs.FargateTaskDefinition(this, "ProxyTask", {
      cpu: 512,
      memoryLimitMiB: 1024,
      runtimePlatform: { cpuArchitecture: ecs.CpuArchitecture.ARM64, operatingSystemFamily: ecs.OperatingSystemFamily.LINUX },
    });

    const allowedGroups = optionalList(ssmParams, "proxyAllowedGroups");
    // fix 6: the forceBackupTranslation switch. The proxy reads it at run time (every 30 s), so it is not
    // one of the deploy-time parameters in config.params.json: "npm run configure" never overwrites it and
    // changing it needs no deployment. Created by hand when wanted; a missing parameter means off.
    const forceBackupParameter = `${ssmParameterHierarchy()}forceBackupTranslation`;
    // Browsers send the page's origin on the WebSocket upgrade; the callback URLs are the app's URLs.
    const allowedOrigins = String(ssmParams.cognitoCallbackUrls)
      .split(",")
      .map((url) => url.trim())
      .filter(Boolean);

    taskDefinition.addContainer("proxy", {
      image: ecs.ContainerImage.fromAsset(path.join(__dirname, "../../../proxy"), { platform: Platform.LINUX_ARM64 }),
      portMappings: [{ containerPort: CONTAINER_PORT }],
      environment: {
        NODE_ENV: "production",
        PORT: String(CONTAINER_PORT),
        LOG_LEVEL: "info",
        COGNITO_USER_POOL_ID: props.userPoolId,
        COGNITO_CLIENT_ID: props.userPoolClientId,
        ALLOWED_GROUPS: allowedGroups.join(","),
        ALLOWED_ORIGINS: allowedOrigins.join(","),
        BEDROCK_REGION: ssmParams.bedrockRegion,
        NOVA_MODEL_ID: ssmParams.novaSonicModelId,
        TRANSCRIBE_REGION: serviceRegion(ssmParams, "transcribeRegion"),
        TRANSLATE_REGION: serviceRegion(ssmParams, "translateRegion"),
        POLLY_REGION: serviceRegion(ssmParams, "pollyRegion"),
        // ECS allows 120 s between SIGTERM and SIGKILL; leave time to close sockets after draining.
        DRAIN_TIMEOUT_MS: "100000",
        // fix 6: with both sides of a call on the backup, each sentence is one Translate + Polly request.
        FALLBACK_REQUESTS_PER_MINUTE: "150",
        FORCE_BACKUP_PARAMETER: forceBackupParameter,
        SSM_REGION: cdk.Aws.REGION,
      },
      logging: ecs.LogDrivers.awsLogs({
        streamPrefix: "proxy",
        logGroup,
        // Never block the event loop on log delivery.
        mode: ecs.AwsLogDriverMode.NON_BLOCKING,
        maxBufferSize: cdk.Size.mebibytes(25),
      }),
      readonlyRootFilesystem: true,
      linuxParameters: new ecs.LinuxParameters(this, "ProxyLinuxParameters", { initProcessEnabled: true }),
      stopTimeout: cdk.Duration.seconds(120),
      healthCheck: {
        command: [
          "CMD",
          "node",
          "-e",
          `fetch('http://127.0.0.1:${CONTAINER_PORT}/healthz').then((r) => process.exit(r.ok ? 0 : 1), () => process.exit(1))`,
        ],
        interval: cdk.Duration.seconds(15),
        timeout: cdk.Duration.seconds(5),
        retries: 3,
        startPeriod: cdk.Duration.seconds(15),
      },
    });

    // Least privilege: the four calls the webapp makes, limited to the configured model and Regions.
    const inRegion = (paramName: string) => ({ StringEquals: { "aws:RequestedRegion": serviceRegion(ssmParams, paramName) } });
    taskDefinition.taskRole.addToPrincipalPolicy(
      new iam.PolicyStatement({
        actions: ["bedrock:InvokeModel"], // the IAM action for InvokeModelWithBidirectionalStream
        resources: [`arn:${cdk.Aws.PARTITION}:bedrock:${ssmParams.bedrockRegion}::foundation-model/${ssmParams.novaSonicModelId}`],
      })
    );
    // These actions do not support resource-level permissions, hence "*" with a Region condition.
    taskDefinition.taskRole.addToPrincipalPolicy(
      new iam.PolicyStatement({ actions: ["transcribe:StartStreamTranscription"], resources: ["*"], conditions: inRegion("transcribeRegion") })
    );
    taskDefinition.taskRole.addToPrincipalPolicy(
      new iam.PolicyStatement({ actions: ["translate:TranslateText"], resources: ["*"], conditions: inRegion("translateRegion") })
    );
    taskDefinition.taskRole.addToPrincipalPolicy(
      new iam.PolicyStatement({ actions: ["polly:SynthesizeSpeech"], resources: ["*"], conditions: inRegion("pollyRegion") })
    );
    // fix 6: read-only access to the forceBackupTranslation parameter, and nothing else in Parameter Store.
    taskDefinition.taskRole.addToPrincipalPolicy(
      new iam.PolicyStatement({
        actions: ["ssm:GetParameter"],
        // A parameter ARN is "parameter" + the name, with exactly one slash between them.
        resources: [`arn:${cdk.Aws.PARTITION}:ssm:${cdk.Aws.REGION}:${cdk.Aws.ACCOUNT_ID}:parameter/${forceBackupParameter.replace(/^\/+/, "")}`],
      })
    );

    const cluster = new ecs.Cluster(this, "ProxyCluster", {
      vpc,
      containerInsightsV2: ecs.ContainerInsights.ENABLED,
    });

    const service = new ecs.FargateService(this, "ProxyService", {
      cluster,
      taskDefinition,
      desiredCount: 2,
      minHealthyPercent: 100,
      maxHealthyPercent: 200,
      circuitBreaker: { enable: true, rollback: true },
      vpcSubnets: { subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS },
      securityGroups: [serviceSecurityGroup],
      assignPublicIp: false,
      enableExecuteCommand: false,
      healthCheckGracePeriod: cdk.Duration.seconds(30),
      propagateTags: ecs.PropagatedTagSource.SERVICE,
    });

    listener.addTargets("Proxy", {
      port: CONTAINER_PORT,
      protocol: elbv2.ApplicationProtocol.HTTP,
      targets: [service],
      deregistrationDelay: DEREGISTRATION_DELAY,
      healthCheck: {
        path: "/healthz",
        healthyHttpCodes: "200",
        interval: cdk.Duration.seconds(10),
        timeout: cdk.Duration.seconds(5),
        healthyThresholdCount: 2,
        unhealthyThresholdCount: 3,
      },
    });

    // Sessions are long-lived WebSockets, so CPU (audio relay) is the load signal, not request count.
    const scaling = service.autoScaleTaskCount({ minCapacity: 2, maxCapacity: 10 });
    scaling.scaleOnCpuUtilization("ProxyCpuScaling", {
      targetUtilizationPercent: 50,
      scaleOutCooldown: cdk.Duration.seconds(60),
      scaleInCooldown: cdk.Duration.seconds(300),
    });

    new cdk.CfnOutput(this, "ProxyLogGroupName", { value: logGroup.logGroupName });
  }
}
