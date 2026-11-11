// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0

const REQUIRED = ["BEDROCK_REGION", "NOVA_MODEL_ID"];
// The sign-in, set by AUTH_MODE. oidc (the default): the page signs in with the corporate identity provider
// itself and sends its access token, which the proxy checks. bff: the server-side sign-in (sessionAuth.js): the
// proxy signs agents in with the identity provider's client secret and the browser holds only a session cookie.
const AUTH_MODES = ["oidc", "bff"];
// off: plain HTTP (local runs). self-signed: HTTPS with a certificate the proxy makes at start-up
// (selfSignedCert.js), so traffic from the load balancer is encrypted too.
const SERVER_TLS_MODES = ["off", "self-signed"];

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
 * The corporate identity provider (OIDC), which signs the agents' access tokens. Without an issuer the proxy
 * still starts and serves the webapp, but rejects every token (the identity provider's client may not exist
 * yet); a half-filled configuration fails startup.
 */
function oidcConfig(env, allowedGroups) {
  const issuer = env.OIDC_ISSUER?.trim();
  if (!issuer) return Object.freeze({ configured: false });
  const audience = env.OIDC_AUDIENCE?.trim();
  const jwksUri = env.OIDC_JWKS_URI?.trim();
  const groupClaim = env.OIDC_GROUP_CLAIM?.trim() || null;
  const missing = [
    ...(audience ? [] : ["OIDC_AUDIENCE"]),
    ...(jwksUri ? [] : ["OIDC_JWKS_URI"]),
    ...(allowedGroups.length && !groupClaim ? ["OIDC_GROUP_CLAIM"] : []),
  ];
  if (missing.length) throw new Error(`OIDC_ISSUER is set, so these are required too: ${missing.join(", ")}`);
  if (new URL(jwksUri).protocol !== "https:") throw new Error("OIDC_JWKS_URI must be an https URL");
  // The issuer is compared with the token's "iss" claim exactly, so it is not normalised.
  return Object.freeze({ configured: true, issuer, audience, jwksUri, groupClaim, allowedGroups });
}

const httpsUrl = (env, name) => {
  const value = env[name]?.trim() || null;
  if (value && new URL(value).protocol !== "https:") throw new Error(`${name} must be an https URL`);
  return value;
};

/**
 * The server-side sign-in (AUTH_MODE=bff). The session key is always required: test sign-in sessions use it
 * too. Without OIDC_ISSUER the identity provider is not set up yet and only the test sign-in works; with it,
 * a half-filled client fails startup. Secrets (the client secret, the session key) are named here, never
 * given: the proxy reads them from Secrets Manager.
 */
function bffConfig(env, allowedGroups) {
  const sessionKeySecretId = env.SESSION_KEY_SECRET_ID?.trim();
  if (!sessionKeySecretId) throw new Error("AUTH_MODE=bff needs SESSION_KEY_SECRET_ID (the session key in Secrets Manager)");
  const settings = {
    sessionKeySecretId,
    // How long a sign-in lasts at most (keep it within Ping's refresh token lifetime), and how often it is
    // re-checked with Ping. A user removed at Ping loses access within about two checks.
    sessionMs: positiveInt(env, "SESSION_HOURS", 12) * 60 * 60_000,
    checkMs: positiveInt(env, "SESSION_CHECK_MINUTES", 30) * 60_000,
    secretsRefreshMs: positiveInt(env, "SECRETS_REFRESH_MS", 300_000),
  };
  const issuer = env.OIDC_ISSUER?.trim();
  if (!issuer) return Object.freeze({ ...settings, oidc: Object.freeze({ configured: false }) });

  const required = ["OIDC_CLIENT_ID", "OIDC_CLIENT_SECRET_ID", "OIDC_REDIRECT_URI", "OIDC_AUTHORIZATION_ENDPOINT", "OIDC_TOKEN_ENDPOINT", "OIDC_JWKS_URI"];
  const groupClaim = env.OIDC_GROUP_CLAIM?.trim() || null;
  const missing = [...required.filter((name) => !env[name]?.trim()), ...(allowedGroups.length && !groupClaim ? ["OIDC_GROUP_CLAIM"] : [])];
  if (missing.length) throw new Error(`OIDC_ISSUER is set, so these are required too: ${missing.join(", ")}`);
  // The site's root, written exactly as registered at the identity provider: the proxy takes its answer at "/".
  const redirectUri = httpsUrl(env, "OIDC_REDIRECT_URI");
  const redirect = new URL(redirectUri);
  if (redirect.pathname !== "/" || redirect.search || redirect.hash) {
    throw new Error("OIDC_REDIRECT_URI must be the site's root address, for example https://v2v.example.com");
  }
  return Object.freeze({
    ...settings,
    oidc: Object.freeze({
      configured: true,
      // Compared with the ID token's "iss" exactly, so it is not normalised.
      issuer,
      clientId: env.OIDC_CLIENT_ID.trim(),
      clientSecretId: env.OIDC_CLIENT_SECRET_ID.trim(),
      scope: env.OIDC_SCOPE?.trim() || "openid",
      redirectUri,
      postLogoutRedirectUri: env.OIDC_POST_LOGOUT_REDIRECT_URI?.trim() || redirectUri,
      authorizationEndpoint: httpsUrl(env, "OIDC_AUTHORIZATION_ENDPOINT"),
      tokenEndpoint: httpsUrl(env, "OIDC_TOKEN_ENDPOINT"),
      jwksUri: httpsUrl(env, "OIDC_JWKS_URI"),
      revocationEndpoint: httpsUrl(env, "OIDC_REVOCATION_ENDPOINT"),
      endSessionEndpoint: httpsUrl(env, "OIDC_END_SESSION_ENDPOINT"),
      userinfoEndpoint: httpsUrl(env, "OIDC_USERINFO_ENDPOINT"),
      groupClaim,
      allowedGroups,
    }),
  });
}

/**
 * The webapp, which this proxy serves: the built files in WEBAPP_DIR (set by the Dockerfile), and the settings
 * the webapp reads from /frontend-config.js. Not set (local development with the Vite dev server): the proxy
 * serves only /ws, /api and /healthz.
 */
function siteConfig(env) {
  const dir = env.WEBAPP_DIR?.trim();
  if (!dir) return null;
  let webappConfig;
  try {
    webappConfig = JSON.parse(env.WEBAPP_CONFIG ?? "");
  } catch {
    throw new Error("WEBAPP_CONFIG must be a JSON object when WEBAPP_DIR is set");
  }
  if (webappConfig === null || typeof webappConfig !== "object" || Array.isArray(webappConfig)) {
    throw new Error("WEBAPP_CONFIG must be a JSON object when WEBAPP_DIR is set");
  }
  return Object.freeze({
    dir,
    webappConfig,
    contentSecurityPolicy: env.CONTENT_SECURITY_POLICY?.trim() || null,
    // Report-only unless explicitly enforced.
    cspReportOnly: env.CSP_REPORT_ONLY?.trim().toLowerCase() !== "false",
  });
}

/**
 * Voicemail playback: the VMX3 recordings bucket, which the proxy reads recordings from (GET /api/voicemail).
 * Not set: there is no voicemail playback.
 */
function voicemailConfig(env, bedrockRegion) {
  const bucket = env.VOICEMAIL_BUCKET?.trim();
  if (!bucket) return null;
  if (!/^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$/.test(bucket)) throw new Error(`VOICEMAIL_BUCKET is not a valid bucket name: "${bucket}"`);
  return Object.freeze({ bucket, region: env.VOICEMAIL_REGION?.trim() || env.AWS_REGION?.trim() || bedrockRegion });
}

/**
 * Reads and validates the proxy configuration from environment variables.
 * Fails fast on anything missing so a misconfigured task never becomes healthy.
 */
export function loadConfig(env = process.env) {
  const authMode = env.AUTH_MODE?.trim().toLowerCase() || "oidc";
  if (!AUTH_MODES.includes(authMode)) throw new Error(`AUTH_MODE must be one of ${AUTH_MODES.join(", ")}, got "${env.AUTH_MODE}"`);
  const missing = REQUIRED.filter((name) => !env[name]?.trim());
  if (missing.length) throw new Error(`Missing required environment variables: ${missing.join(", ")}`);

  const production = env.NODE_ENV === "production";
  // Normalised to bare origins so "https://v2v.example.com/" matches the browser's "https://v2v.example.com".
  const allowedOrigins = list(env.ALLOWED_ORIGINS).map((origin) => new URL(origin).origin);
  if (production && allowedOrigins.length === 0) {
    throw new Error("ALLOWED_ORIGINS is required when NODE_ENV=production");
  }

  const serverTls = env.SERVER_TLS?.trim().toLowerCase() || "off";
  if (!SERVER_TLS_MODES.includes(serverTls)) throw new Error(`SERVER_TLS must be one of ${SERVER_TLS_MODES.join(", ")}, got "${env.SERVER_TLS}"`);

  const bedrockRegion = env.BEDROCK_REGION.trim();
  const allowedGroups = list(env.ALLOWED_GROUPS);
  return Object.freeze({
    serverTls,
    port: positiveInt(env, "PORT", serverTls === "off" ? 8080 : 8443),
    logLevel: env.LOG_LEVEL || "info",
    authMode,
    oidc: authMode === "oidc" ? oidcConfig(env, allowedGroups) : null,
    bff: authMode === "bff" ? bffConfig(env, allowedGroups) : null,
    allowedGroups,
    site: siteConfig(env),
    allowedOrigins,
    bedrockRegion,
    novaModelId: env.NOVA_MODEL_ID.trim(),
    transcribeRegion: env.TRANSCRIBE_REGION?.trim() || bedrockRegion,
    translateRegion: env.TRANSLATE_REGION?.trim() || bedrockRegion,
    pollyRegion: env.POLLY_REGION?.trim() || bedrockRegion,
    // fix 6: the forceBackupTranslation switch in Parameter Store (full name). Not set: the switch is off.
    forceBackupParameter: env.FORCE_BACKUP_PARAMETER?.trim() || null,
    // The temporary test sign-in's secret in Secrets Manager, its password (services/testSignIn.js). Not set:
    // there is no test sign-in.
    testSignInSecretId: env.TEST_SIGN_IN_SECRET_ID?.trim() || null,
    ssmRegion: env.SSM_REGION?.trim() || env.AWS_REGION?.trim() || bedrockRegion,
    // Secrets Manager: the test sign-in password, and with AUTH_MODE=bff the client secret and the session key.
    secretsRegion: env.SECRETS_REGION?.trim() || env.AWS_REGION?.trim() || bedrockRegion,
    voicemail: voicemailConfig(env, bedrockRegion),
    limits: Object.freeze({
      maxConnections: positiveInt(env, "MAX_CONNECTIONS", 2000),
      maxConnectionsPerUser: positiveInt(env, "MAX_CONNECTIONS_PER_USER", 12),
      fallbackRequestsPerMinute: positiveInt(env, "FALLBACK_REQUESTS_PER_MINUTE", 60),
      voicemailRequestsPerMinute: positiveInt(env, "VOICEMAIL_REQUESTS_PER_MINUTE", 30),
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
      testSignInRefreshMs: positiveInt(env, "TEST_SIGN_IN_REFRESH_MS", 30_000),
    }),
  });
}
