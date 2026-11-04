// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import { loadConfig } from "./config.js";
import { createLogger, errorFields } from "./logger.js";
import { createOidcVerifier, createRejectingVerifier } from "./auth.js";
import { createAwsClients } from "./awsClients.js";
import { createProxyServer } from "./server.js";
import { createTranslationModeSource } from "./services/translationMode.js";
import { createTestSignIn, withTestSignIn } from "./services/testSignIn.js";
import { createSecretSource } from "./services/secrets.js";
import { createOidcClient } from "./services/oidcClient.js";
import { createSealer } from "./session.js";
import { createSessionAuth } from "./sessionAuth.js";
import { createSelfSignedCertificate } from "./selfSignedCert.js";

const config = loadConfig();
const logger = createLogger(config.logLevel);

process.on("unhandledRejection", (err) => logger.error("unhandled rejection", errorFields(err)));
process.on("uncaughtException", (err) => {
  logger.error("uncaught exception", errorFields(err));
  process.exit(1);
});

let verifier;
if (config.authMode === "bff") {
  // The server-side sign-in checks session cookies (sessionAuth.js), not tokens.
  verifier = createRejectingVerifier();
} else if (config.oidc.configured) {
  verifier = createOidcVerifier(config.oidc);
  // The identity provider's keys are the one download from outside AWS, over the corporate network. If it
  // fails, start anyway: the site stays up, the error is in the log, and each sign-in retries the download.
  try {
    await verifier.hydrate();
  } catch (err) {
    logger.error("identity provider keys unavailable", { jwksUri: config.oidc.jwksUri, ...errorFields(err) });
  }
} else {
  verifier = createRejectingVerifier();
  logger.warn("no identity provider configured: every token is rejected until OIDC_ISSUER is set");
}

const clients = createAwsClients(config);
// fix 6: the forceBackupTranslation switch, read in the background (never delays or fails startup).
const translationMode = createTranslationModeSource({
  ssm: clients.ssm,
  parameterName: config.forceBackupParameter,
  refreshMs: config.timeouts.translationModeRefreshMs,
  logger,
});
translationMode.start();
// The temporary test sign-in, switched on and off in Parameter Store.
const testSignIn = config.testSignInParameter
  ? createTestSignIn({ ssm: clients.ssm, parameterName: config.testSignInParameter, refreshMs: config.timeouts.testSignInRefreshMs, logger })
  : null;
if (testSignIn) {
  await testSignIn.start();
  if (config.authMode !== "bff") verifier = withTestSignIn(verifier, testSignIn);
}

// The server-side sign-in (AUTH_MODE=bff). The secrets are read before accepting traffic; if Secrets Manager
// cannot be reached, start anyway: the site stays up, the error is in the log, and the read is retried.
let sessionKey = null;
let clientSecret = null;
let sessionAuth = null;
if (config.bff) {
  const secretSource = (secretId, label, withPrevious) =>
    createSecretSource({ client: clients.secrets, secretId, withPrevious, refreshMs: config.bff.secretsRefreshMs, label, logger });
  sessionKey = secretSource(config.bff.sessionKeySecretId, "session key", true);
  clientSecret = config.bff.oidc.configured ? secretSource(config.bff.oidc.clientSecretId, "identity provider client secret", false) : null;
  await Promise.all([sessionKey.start(), clientSecret?.start()]);
  if (!config.bff.oidc.configured) logger.warn("no identity provider configured: only the test sign-in can sign in until OIDC_ISSUER is set");
  sessionAuth = createSessionAuth({
    settings: config.bff,
    oidc: config.bff.oidc.configured ? createOidcClient(config.bff.oidc, { clientSecret }) : null,
    sealer: createSealer({ keys: () => [sessionKey.current, sessionKey.previous] }),
    testSignIn,
    logger,
  });
}
// SERVER_TLS=self-signed: a new key and certificate for this task, kept in memory only.
const tls = config.serverTls === "self-signed" ? await createSelfSignedCertificate() : null;
const proxy = createProxyServer({ config, verifier, clients, logger, translationMode, testSignIn, sessionAuth, tls });
const address = await proxy.listen(config.port);
logger.info("proxy listening", {
  port: address.port,
  protocol: tls ? "https" : "http",
  ...(tls ? { certificateSha256: tls.fingerprint256 } : {}),
  bedrockRegion: config.bedrockRegion,
  transcribeRegion: config.transcribeRegion,
  translateRegion: config.translateRegion,
  pollyRegion: config.pollyRegion,
  forceBackupParameter: config.forceBackupParameter,
  allowedOrigins: config.allowedOrigins,
  authMode: config.authMode,
  ...(config.bff
    ? {
        identityProviderConfigured: config.bff.oidc.configured,
        sessionKeyLoaded: sessionKey.current != null,
        clientSecretLoaded: clientSecret ? clientSecret.current != null : null,
        sessionHours: config.bff.sessionMs / 3_600_000,
        sessionCheckMinutes: config.bff.checkMs / 60_000,
      }
    : {}),
  groupRestricted: config.allowedGroups.length > 0,
  testSignInParameter: config.testSignInParameter,
  siteFiles: proxy.siteFileCount,
});

let stopping = false;
async function stop(signal) {
  if (stopping) return;
  stopping = true;
  logger.info("shutdown requested", { signal });
  translationMode.stop();
  testSignIn?.stop();
  sessionKey?.stop();
  clientSecret?.stop();
  try {
    await proxy.shutdown();
  } finally {
    process.exit(0);
  }
}
process.on("SIGTERM", () => stop("SIGTERM"));
process.on("SIGINT", () => stop("SIGINT"));
