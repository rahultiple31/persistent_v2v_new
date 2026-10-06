// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0

const REQUIRED = ["COGNITO_USER_POOL_ID", "COGNITO_CLIENT_ID", "BEDROCK_REGION", "NOVA_MODEL_ID"];

function list(value) {
  return (value || "")
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
}

function positiveInt(env, name, defaultValue) {
  const raw = env[name];
  if (raw == null || raw === "") return defaultValue;
  const value = Number(raw);
  if (!Number.isInteger(value) || value <= 0) throw new Error(`${name} must be a positive integer, got "${raw}"`);
  return value;
}

/**
 * Reads and validates the proxy configuration from environment variables.
 * Fails fast on anything missing so a misconfigured task never becomes healthy.
 */
export function loadConfig(env = process.env) {
  const missing = REQUIRED.filter((name) => !env[name]?.trim());
  if (missing.length) throw new Error(`Missing required environment variables: ${missing.join(", ")}`);

  const production = env.NODE_ENV === "production";
  // Normalised to bare origins so "https://x.cloudfront.net/" matches the browser's "https://x.cloudfront.net".
  const allowedOrigins = list(env.ALLOWED_ORIGINS).map((origin) => new URL(origin).origin);
  if (production && allowedOrigins.length === 0) {
    throw new Error("ALLOWED_ORIGINS is required when NODE_ENV=production");
  }

  const bedrockRegion = env.BEDROCK_REGION.trim();
  return Object.freeze({
    port: positiveInt(env, "PORT", 8080),
    logLevel: env.LOG_LEVEL || "info",
    cognito: Object.freeze({
      userPoolId: env.COGNITO_USER_POOL_ID.trim(),
      clientId: env.COGNITO_CLIENT_ID.trim(),
      allowedGroups: list(env.ALLOWED_GROUPS),
    }),
    allowedOrigins,
    bedrockRegion,
    novaModelId: env.NOVA_MODEL_ID.trim(),
    transcribeRegion: env.TRANSCRIBE_REGION?.trim() || bedrockRegion,
    translateRegion: env.TRANSLATE_REGION?.trim() || bedrockRegion,
    pollyRegion: env.POLLY_REGION?.trim() || bedrockRegion,
    // fix 6: the forceBackupTranslation switch in Parameter Store (full name). Not set: the switch is off.
    forceBackupParameter: env.FORCE_BACKUP_PARAMETER?.trim() || null,
    ssmRegion: env.SSM_REGION?.trim() || env.AWS_REGION?.trim() || bedrockRegion,
    limits: Object.freeze({
      maxConnections: positiveInt(env, "MAX_CONNECTIONS", 2000),
      maxConnectionsPerUser: positiveInt(env, "MAX_CONNECTIONS_PER_USER", 12),
      fallbackRequestsPerMinute: positiveInt(env, "FALLBACK_REQUESTS_PER_MINUTE", 60),
    }),
    timeouts: Object.freeze({
      authMs: positiveInt(env, "AUTH_TIMEOUT_MS", 10_000),
      // A pooled socket that is authenticated but never started. The webapp recycles its pool well before this.
      idleUnstartedMs: positiveInt(env, "IDLE_UNSTARTED_TIMEOUT_MS", 10 * 60_000),
      // Nova Sonic ends sessions at 8 minutes itself; this only guards against a stuck upstream.
      novaMaxMs: positiveInt(env, "NOVA_MAX_SESSION_MS", 9 * 60_000),
      // Transcribe streaming's own limit is 4 hours.
      transcribeMaxMs: positiveInt(env, "TRANSCRIBE_MAX_SESSION_MS", 4 * 60 * 60_000),
      heartbeatMs: positiveInt(env, "HEARTBEAT_INTERVAL_MS", 25_000),
      drainMs: positiveInt(env, "DRAIN_TIMEOUT_MS", 100_000),
      // fix 6: how often the forceBackupTranslation switch is read.
      translationModeRefreshMs: positiveInt(env, "TRANSLATION_MODE_REFRESH_MS", 30_000),
    }),
  });
}
