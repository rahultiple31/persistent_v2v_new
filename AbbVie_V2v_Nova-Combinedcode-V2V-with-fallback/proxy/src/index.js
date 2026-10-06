// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import { loadConfig } from "./config.js";
import { createLogger, errorFields } from "./logger.js";
import { createCognitoVerifier } from "./auth.js";
import { createAwsClients } from "./awsClients.js";
import { createProxyServer } from "./server.js";
import { createTranslationModeSource } from "./services/translationMode.js";

const config = loadConfig();
const logger = createLogger(config.logLevel);

process.on("unhandledRejection", (err) => logger.error("unhandled rejection", errorFields(err)));
process.on("uncaughtException", (err) => {
  logger.error("uncaught exception", errorFields(err));
  process.exit(1);
});

const verifier = createCognitoVerifier(config.cognito);
// Fetch the user pool's signing keys before accepting traffic, so the first sign-in pays no JWKS round
// trip, and a wrong user pool ID fails the deployment instead of every request.
await verifier.hydrate();

const clients = createAwsClients(config);
// fix 6: the forceBackupTranslation switch, read in the background (never delays or fails startup).
const translationMode = createTranslationModeSource({
  ssm: clients.ssm,
  parameterName: config.forceBackupParameter,
  refreshMs: config.timeouts.translationModeRefreshMs,
  logger,
});
translationMode.start();
const proxy = createProxyServer({ config, verifier, clients, logger, translationMode });
const address = await proxy.listen(config.port);
logger.info("proxy listening", {
  port: address.port,
  bedrockRegion: config.bedrockRegion,
  transcribeRegion: config.transcribeRegion,
  translateRegion: config.translateRegion,
  pollyRegion: config.pollyRegion,
  forceBackupParameter: config.forceBackupParameter,
  allowedOrigins: config.allowedOrigins,
  groupRestricted: config.cognito.allowedGroups.length > 0,
});

let stopping = false;
async function stop(signal) {
  if (stopping) return;
  stopping = true;
  logger.info("shutdown requested", { signal });
  translationMode.stop();
  try {
    await proxy.shutdown();
  } finally {
    process.exit(0);
  }
}
process.on("SIGTERM", () => stop("SIGTERM"));
process.on("SIGINT", () => stop("SIGINT"));
