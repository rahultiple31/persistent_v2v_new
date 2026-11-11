// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import { BedrockRuntimeClient } from "@aws-sdk/client-bedrock-runtime";
import { TranscribeStreamingClient } from "@aws-sdk/client-transcribe-streaming";
import { TranslateClient } from "@aws-sdk/client-translate";
import { PollyClient } from "@aws-sdk/client-polly";
import { SSMClient } from "@aws-sdk/client-ssm";
import { SecretsManagerClient } from "@aws-sdk/client-secrets-manager";
import { S3Client } from "@aws-sdk/client-s3";
import { NodeHttp2Handler, NodeHttpHandler } from "@smithy/node-http-handler";

/**
 * One long-lived client per service, shared by every session on the task. Credentials come from the
 * ECS task role through the SDK's default provider chain and are refreshed by the SDK.
 */
export function createAwsClients(config) {
  return {
    // One HTTP/2 connection per Nova Sonic stream, the SDK's default for bidirectional streams. Do not
    // share connections between streams: a shared connection left idle for more than 350 seconds is
    // silently dropped by the network path (interface VPC endpoints have a fixed 350-second idle
    // timeout), and the next session start on it fails. From inside the region the extra TCP + TLS
    // handshake per stream costs only milliseconds.
    bedrock: new BedrockRuntimeClient({
      region: config.bedrockRegion,
      requestHandler: new NodeHttp2Handler({
        requestTimeout: config.timeouts.novaMaxMs,
        sessionTimeout: config.timeouts.novaMaxMs,
        disableConcurrentStreams: true,
      }),
    }),
    // Transcribe streams last for the whole call, so a handshake per stream is negligible; keep the
    // SDK's default of one connection per stream.
    transcribe: new TranscribeStreamingClient({ region: config.transcribeRegion }),
    translate: new TranslateClient({ region: config.translateRegion }),
    polly: new PollyClient({ region: config.pollyRegion }),
    // fix 6: reads the forceBackupTranslation switch; only when a parameter name is configured.
    ssm: config.forceBackupParameter ? new SSMClient({ region: config.ssmRegion }) : null,
    // The test sign-in password, and the server-side sign-in's (AUTH_MODE=bff) client secret and session key.
    secrets: config.bff || config.testSignInSecretId ? new SecretsManagerClient({ region: config.secretsRegion }) : null,
    // Voicemail playback: reads recordings from the VMX3 bucket (through the VPC's S3 gateway endpoint). A
    // stalled read gives up after 30 s without data, so the agent sees an error rather than waiting forever.
    s3: config.voicemail
      ? new S3Client({ region: config.voicemail.region, requestHandler: new NodeHttpHandler({ connectionTimeout: 5_000, socketTimeout: 30_000 }) })
      : null,
  };
}