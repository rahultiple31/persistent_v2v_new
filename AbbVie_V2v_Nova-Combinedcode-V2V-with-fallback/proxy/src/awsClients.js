// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import { BedrockRuntimeClient } from "@aws-sdk/client-bedrock-runtime";
import { TranscribeStreamingClient } from "@aws-sdk/client-transcribe-streaming";
import { TranslateClient } from "@aws-sdk/client-translate";
import { PollyClient } from "@aws-sdk/client-polly";
import { SSMClient } from "@aws-sdk/client-ssm";
import { NodeHttp2Handler } from "@smithy/node-http-handler";

/**
 * One long-lived client per service, shared by every session on the task. Credentials come from the
 * ECS task role through the SDK's default provider chain and are refreshed by the SDK.
 */
export function createAwsClients(config) {
  return {
    // One HTTP/2 connection per Nova Sonic stream, the SDK's default for bidirectional streams. Do not
    // share connections between streams: a shared connection left idle for more than 350 seconds is
    // silently dropped by the NAT gateway, and the next session start on it fails. From inside the
    // region the extra TCP + TLS handshake per stream costs only milliseconds.
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
  };
}