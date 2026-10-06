// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import { COGNITO_CONFIG, PROXY_CONFIG } from "../config";
import { LOGGER_PREFIX } from "../constants";

// Earlier versions persisted AWS credentials and Cognito tokens in localStorage; remove any left behind.
try {
  for (const key of ["awsCredentials", "accessToken", "idToken", "refreshToken"]) localStorage.removeItem(key);
} catch {
  // Storage unavailable: nothing to remove.
}

export function setRedirectURI(redirectURI) {
  const currentUrl = redirectURI ?? window.location.href;
  const url = new URL(currentUrl);
  const redirectUri = `${url.origin}${url.pathname.replace(/\/+$/, "")}`;
  //set redirect uri in local storage
  localStorage.setItem("redirectUri", redirectUri);
}

function getRedirectURI() {
  return localStorage.getItem("redirectUri");
}

// PKCE verifier and state for the sign-in in progress. They live in this tab's sessionStorage from the
// redirect to Cognito until the redirect back, and are removed as soon as they are used.
const PKCE_VERIFIER_KEY = "v2vPkceVerifier";
const OAUTH_STATE_KEY = "v2vOAuthState";

function base64Url(bytes) {
  let binary = "";
  bytes.forEach((b) => {
    binary += String.fromCharCode(b);
  });
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function randomToken(byteLength) {
  return base64Url(crypto.getRandomValues(new Uint8Array(byteLength)));
}

// Generate the Cognito hosted UI URL.
//  - PKCE (S256): Cognito only exchanges the code together with the verifier kept in this tab, so an
//    authorization code taken from browser history, logs or an extension is useless on its own.
//  - state: the redirect back is accepted only if it answers the sign-in this tab started, which stops a
//    forged redirect from signing the browser in as someone else (login CSRF).
export async function getLoginUrl() {
  const verifier = randomToken(32);
  const state = randomToken(16);
  const challenge = base64Url(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier))));
  sessionStorage.setItem(PKCE_VERIFIER_KEY, verifier);
  sessionStorage.setItem(OAUTH_STATE_KEY, state);

  const params = new URLSearchParams({
    client_id: COGNITO_CONFIG.clientId,
    response_type: "code",
    scope: "email openid profile",
    redirect_uri: getRedirectURI(),
    state,
    code_challenge: challenge,
    code_challenge_method: "S256",
  });

  // With an SSO provider configured, go straight to the corporate IdP instead of the Cognito sign-in page.
  if (COGNITO_CONFIG.ssoProviderName) {
    params.set("identity_provider", COGNITO_CONFIG.ssoProviderName);
    return `${COGNITO_CONFIG.cognitoDomain}/oauth2/authorize?${params.toString()}`;
  }

  return `${COGNITO_CONFIG.cognitoDomain}/login?${params.toString()}`;
}

// Handle the redirect from Cognito
export async function handleRedirect() {
  const urlParams = new URLSearchParams(window.location.search);
  const code = urlParams.get("code");

  if (code) {
    const expectedState = sessionStorage.getItem(OAUTH_STATE_KEY);
    const verifier = sessionStorage.getItem(PKCE_VERIFIER_KEY);
    // One use only, and the code leaves the address bar whatever happens next.
    sessionStorage.removeItem(OAUTH_STATE_KEY);
    sessionStorage.removeItem(PKCE_VERIFIER_KEY);
    window.history.replaceState({}, document.title, window.location.pathname);

    if (!expectedState || !verifier || urlParams.get("state") !== expectedState) {
      console.error(`${LOGGER_PREFIX} - handleRedirect - sign-in response rejected: it does not match a sign-in started in this tab`);
      return false;
    }
    try {
      // Exchange the code for tokens
      const tokens = await getTokens(code, verifier);
      // Store tokens
      setTokens(tokens);
      return true;
    } catch (error) {
      console.error(`${LOGGER_PREFIX} - handleRedirect - Error exchanging code for tokens:`, error);
      return false;
    }
  }
  return false;
}

// Exchange authorization code for tokens
async function getTokens(code, codeVerifier) {
  const params = new URLSearchParams({
    grant_type: "authorization_code",
    client_id: COGNITO_CONFIG.clientId,
    code: code,
    redirect_uri: getRedirectURI(),
    code_verifier: codeVerifier,
  });

  const response = await fetch(`${COGNITO_CONFIG.cognitoDomain}/oauth2/token`, {
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: params.toString(),
  });

  if (!response.ok) {
    throw new Error("Failed to exchange code for tokens");
  }
  const tokens = await response.json();
  const idTokenPayload = decodeToken(tokens.id_token);
  const idTokenExpires = new Date(idTokenPayload.exp * 1000);
  const accessTokenPayload = decodeToken(tokens.access_token);
  const accessTokenExpires = new Date(accessTokenPayload.exp * 1000);
  console.info(
    `${LOGGER_PREFIX} - getTokens - Tokens obtained, id_token expires at ${idTokenExpires.toISOString()}, access_token expires at ${accessTokenExpires.toISOString()}`
  );
  return tokens;
}

// Cognito tokens, held in this page's memory only: they are never written to disk, where malware or the next
// user of a shared PC could copy them, and they are gone when the tab closes. A reload therefore signs in
// again, which with SSO is a few automatic redirects.
let _tokens = null;

function setTokens(tokens) {
  _tokens = {
    accessToken: tokens.access_token,
    idToken: tokens.id_token,
    // A refresh response carries no new refresh token: keep the one from sign-in.
    refreshToken: tokens.refresh_token ?? _tokens?.refreshToken ?? null,
  };
}

function getToken(name) {
  return _tokens?.[name] ?? null;
}

// Direct mode only (proxy disabled). Held in memory, never in storage: other tabs, extensions reading
// storage, and the next user of a shared PC cannot pick them up, and they are gone when the tab closes.
let _awsCredentials = null;

function setAwsCredentials(awsCredentials) {
  _awsCredentials = awsCredentials;
}

function getAwsCredentials() {
  return _awsCredentials;
}

export function isTokenExpired(token) {
  if (token == null) return true;

  try {
    // Get payload from JWT token (second part between dots)
    const payload = JSON.parse(atob(token.split(".")[1]));

    // exp is in seconds, convert current time to seconds
    const currentTime = Math.floor(Date.now() / 1000);

    // Check if token has expired
    return payload.exp < currentTime;
  } catch (error) {
    console.error(`${LOGGER_PREFIX} - getAwsCredentials - Error checking token expiration:`, error);
    return true;
  }
}

export async function refreshTokens() {
  const refreshToken = getToken("refreshToken");
  try {
    if (refreshToken == null) {
      throw new Error("No refresh token available");
    }

    const params = new URLSearchParams({
      grant_type: "refresh_token",
      client_id: COGNITO_CONFIG.clientId,
      refresh_token: refreshToken,
    });

    const response = await fetch(`${COGNITO_CONFIG.cognitoDomain}/oauth2/token`, {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: params.toString(),
    });

    if (!response.ok) {
      throw new Error("Failed to refresh tokens");
    }

    const tokens = await response.json();
    const idTokenPayload = decodeToken(tokens.id_token);
    const idTokenExpires = new Date(idTokenPayload.exp * 1000);
    const accessTokenPayload = decodeToken(tokens.access_token);
    const accessTokenExpires = new Date(accessTokenPayload.exp * 1000);
    setTokens(tokens);
    console.info(
      `${LOGGER_PREFIX} - refreshTokens - Tokens refreshed, id_token expire at ${idTokenExpires.toISOString()}, access_token expire at ${accessTokenExpires.toISOString()}`
    );
    return tokens;
  } catch (error) {
    console.error(`${LOGGER_PREFIX} - refreshTokens - Error refreshing tokens:`, error);
    // Sign out, but never in the middle of a call (see endSession).
    endSession("refresh failed");
    throw error;
  }
}

// Update isAuthenticated to check expiration
export function isAuthenticated() {
  const idToken = getToken("idToken");
  const accessToken = getToken("accessToken");
  const refreshToken = getToken("refreshToken");
  if (idToken == null || accessToken == null || refreshToken == null) return false;
  if (isTokenExpired(idToken) || isTokenExpired(accessToken)) return false;
  return true;
}

// Get valid access token (refreshing if needed)
export async function getValidTokens() {
  const idToken = getToken("idToken");
  const accessToken = getToken("accessToken");
  const refreshToken = getToken("refreshToken");

  // The session has already ended and sign-out is waiting for the current call to finish.
  if (pendingSignOut) return;

  if (refreshToken == null) {
    console.error(`${LOGGER_PREFIX} - getValidTokens - No refresh token available`);
    endSession("no refresh token");
    return;
  }

  if (isTokenExpired(idToken) || isTokenExpired(accessToken)) {
    try {
      await refreshTokens();
    } catch (error) {
      console.error(`${LOGGER_PREFIX} - getValidTokens - Error refreshing tokens:`, error);
      // refreshTokens() has already ended the session (or deferred it until the call ends).
      return;
    }
  }
  return {
    accessToken: getToken("accessToken"),
    idToken: getToken("idToken"),
    refreshToken: getToken("refreshToken"),
  };
}

// Helper to decode token payload
export function decodeToken(token) {
  try {
    return JSON.parse(atob(token.split(".")[1]));
  } catch (error) {
    console.error(`${LOGGER_PREFIX} - decodeToken - Error decoding token:`, error);
    return null;
  }
}

// Get user info from token
export function getUserInfo() {
  const token = getToken("idToken");
  if (!token) return null;

  const payload = decodeToken(token);
  return {
    email: payload.email,
    username: payload.preferred_username,
    sub: payload.sub,
  };
}

/**
 * Starts the background Cognito token + AWS credential refresh timer.
 *
 * @param {Function} [onRefresh] - Optional callback invoked AFTER every
 *   successful credential refresh (tokens + AWS credentials both renewed).
 *   Use this to invalidate any SDK clients that cache the old credentials
 *   (e.g. Bedrock, Translate, Polly clients). The callback may be async.
 *
 * GAP 5 FIX: Added optional onRefresh parameter so callers can register
 * client-invalidation hooks without modifying authUtility. Previously only
 * the Nova Sonic Bedrock client was invalidated on refresh; Translate and
 * Polly clients cached stale credentials until the next call attempted and
 * self-healed via hasValidAwsCredentials(). With onRefresh, all SDK clients
 * are proactively cleared the moment new credentials land.
 */
export function startTokenRefreshTimer(onRefresh) {
  const idToken = getToken("idToken");
  const accessToken = getToken("accessToken");

  if (idToken == null || accessToken == null) throw new Error("Unable to startTokenRefreshTimer - No tokens available");

  const idTokenPayload = decodeToken(idToken);
  const accessTokenPayload = decodeToken(accessToken);
  if (idTokenPayload == null || accessTokenPayload == null) throw new Error("Unable to startTokenRefreshTimer - Error decoding tokens");

  // Calculate time until token expires
  const idTokenExpiresIn = idTokenPayload.exp * 1000 - Date.now();
  const accessTokenExpiresIn = accessTokenPayload.exp * 1000 - Date.now();
  const firstTokenExpiresIn = Math.min(idTokenExpiresIn, accessTokenExpiresIn);

  // Refresh 4 minutes before expiration
  let refreshTime = firstTokenExpiresIn - 4 * 60 * 1000;
  if (refreshTime < 0) refreshTime = 0;

  console.info(`${LOGGER_PREFIX} - startTokenRefreshTimer - Token refresh timer set for ${Math.floor(refreshTime / 1000)}s`);
  setTimeout(async () => {
    try {
      await refreshTokens();
      // With the proxy the browser never holds AWS credentials, so there are none to renew.
      if (!PROXY_CONFIG.enabled) await getValidAwsCredentials();
      // Notify registered clients so they discard cached SDK clients built
      // with the now-expired credentials and rebuild on next use.
      if (typeof onRefresh === "function") {
        try { await onRefresh(); } catch (cbErr) {
          console.warn(`${LOGGER_PREFIX} - startTokenRefreshTimer - onRefresh callback error:`, cbErr);
        }
      }
      // Start new timer after refresh, forwarding the same callback.
      startTokenRefreshTimer(onRefresh);
    } catch (error) {
      console.error(`${LOGGER_PREFIX} - startTokenRefreshTimer - Error in refresh timer:`, error);
    }
  }, refreshTime);
}

// ── Session end: never during a call ────────────────────────────────────────
//
// The refresh token lasts one shift (refreshTokenValidityHours). Signing out navigates away from the
// page, which would drop the softphone and any call in progress. So when the session can no longer be
// renewed during a call, sign-out waits until the call has ended; streams that are already running keep
// working meanwhile, only new Nova Sonic / Transcribe sessions need a valid token. The agent is warned
// SESSION_WARNING_MS before the end so they can sign in again between calls.

const SESSION_WARNING_MS = 30 * 60 * 1000;
let isCallActive = () => false;
let notifySession = () => {};
let pendingSignOut = false;

/**
 * main.js registers how to tell whether a call is in progress, and how to show session notices:
 * notify({ type: "expiring", expiresAt }) before the end, notify({ type: "expired" }) when it ended during a call.
 */
export function registerSessionHooks({ callActive, notify }) {
  if (typeof callActive === "function") isCallActive = callActive;
  if (typeof notify === "function") notifySession = notify;
}

/** When the refresh token stops working: the original sign-in time plus refreshTokenValidityHours. */
export function getSessionExpiresAt() {
  const idToken = getToken("idToken");
  if (!idToken) return null;
  const payload = decodeToken(idToken);
  const hours = Number(COGNITO_CONFIG.refreshTokenValidityHours);
  if (!payload?.auth_time || !hours) return null;
  return (payload.auth_time + hours * 3600) * 1000;
}

/** Warns the agent SESSION_WARNING_MS before the session ends. Call once the agent is signed in. */
export function startSessionExpiryWatch() {
  const expiresAt = getSessionExpiresAt();
  if (!expiresAt) return;
  const warnIn = expiresAt - SESSION_WARNING_MS - Date.now();
  setTimeout(() => {
    if (Date.now() < expiresAt) notifySession({ type: "expiring", expiresAt });
  }, Math.max(0, warnIn));
}

function endSession(reason) {
  if (isCallActive()) {
    if (!pendingSignOut) {
      pendingSignOut = true;
      console.warn(`${LOGGER_PREFIX} - session ended (${reason}) during a call: signing out when the call ends`);
      notifySession({ type: "expired" });
    }
    return;
  }
  logout();
}

/** main.js calls this when a call has fully ended, to carry out a sign-out that was waiting for it. */
export function completePendingSignOut() {
  if (pendingSignOut && !isCallActive()) logout();
}

export async function logout() {
  const params = new URLSearchParams({
    client_id: COGNITO_CONFIG.clientId,
    logout_uri: getRedirectURI(),
  });
  const refreshToken = getToken("refreshToken");

  _tokens = null;
  _awsCredentials = null;

  // Revoke the refresh token, so a copy of it cannot mint new access tokens after sign-out. Bounded, so
  // a slow or failed request never holds up the sign-out itself.
  if (refreshToken) {
    try {
      await Promise.race([
        fetch(`${COGNITO_CONFIG.cognitoDomain}/oauth2/revoke`, {
          method: "POST",
          headers: { "Content-Type": "application/x-www-form-urlencoded" },
          body: new URLSearchParams({ token: refreshToken, client_id: COGNITO_CONFIG.clientId }).toString(),
          keepalive: true,
        }),
        new Promise((resolve) => setTimeout(resolve, 2000)),
      ]);
    } catch (error) {
      console.warn(`${LOGGER_PREFIX} - logout - refresh token revocation failed`, error);
    }
  }

  // Redirect to Cognito logout
  window.location.href = `${COGNITO_CONFIG.cognitoDomain}/logout?${params.toString()}`;
}

async function getCognitoIdentityCredentials(idToken) {
  // First, get the Cognito Identity ID
  const identityParams = {
    IdentityPoolId: COGNITO_CONFIG.identityPoolId,
    Logins: {
      [`cognito-idp.${COGNITO_CONFIG.region}.amazonaws.com/${COGNITO_CONFIG.userPoolId}`]: idToken,
    },
  };

  try {
    // Get Identity ID
    const cognitoIdentity = new AWS.CognitoIdentity({
      region: COGNITO_CONFIG.region,
    });
    const { IdentityId } = await cognitoIdentity.getId(identityParams).promise();

    // Get credentials
    const cognitoCredentialsForIdentity = await cognitoIdentity
      .getCredentialsForIdentity({
        IdentityId,
        Logins: {
          [`cognito-idp.${COGNITO_CONFIG.region}.amazonaws.com/${COGNITO_CONFIG.userPoolId}`]: idToken,
        },
      })
      .promise();

    const credentials = {
      accessKeyId: cognitoCredentialsForIdentity.Credentials.AccessKeyId,
      secretAccessKey: cognitoCredentialsForIdentity.Credentials.SecretKey,
      sessionToken: cognitoCredentialsForIdentity.Credentials.SessionToken,
      expiration: cognitoCredentialsForIdentity.Credentials.Expiration,
    };

    console.info(`${LOGGER_PREFIX} - getCognitoIdentityCredentials - Cognito Identity credentials obtained, expire at ${credentials.expiration.toISOString()}`);
    setAwsCredentials(credentials);
    return credentials;
  } catch (error) {
    console.error(`${LOGGER_PREFIX} - getCognitoIdentityCredentials - Error getting Cognito Identity credentials:`, error);
    throw error;
  }
}

/**
 * In-flight credential exchange, shared by every concurrent caller.
 *
 * Pressing Start fires three independent consumers at once — the customer Nova
 * Sonic session, the agent Nova Sonic session and the Transcribe stream — and
 * each called getValidAwsCredentials() before any of them had finished. The
 * cache check at the top only helps once a result exists, so all three missed
 * it and ran the full exchange: a getId round trip followed by a
 * getCredentialsForIdentity round trip, six serialised AWS calls in total for
 * one set of credentials. The captured console shows exactly that, three
 * "Cognito Identity credentials obtained" lines within a second of each other,
 * inside the ~4-5s the Start button took.
 *
 * Holding the promise collapses those three into one.
 */
let _credentialsInFlight = null;

// Get AWS credentials using Cognito Identity Pool
export async function getValidAwsCredentials() {
  if (hasValidAwsCredentials()) {
    return getAwsCredentials();
  }

  // Someone else is already fetching — wait on their result instead of
  // starting a second exchange for the same credentials.
  if (_credentialsInFlight) {
    return _credentialsInFlight;
  }

  _credentialsInFlight = (async () => {
    const tokens = await getValidTokens();

    if (tokens?.accessToken == null || tokens?.idToken == null || tokens?.refreshToken == null) {
      throw new Error("No tokens available");
    }

    return getCognitoIdentityCredentials(tokens.idToken);
  })();

  try {
    return await _credentialsInFlight;
  } catch (error) {
    console.error(`${LOGGER_PREFIX} - getValidAwsCredentials - Error getting AWS credentials:`, error);
    throw error;
  } finally {
    // Cleared on success and on failure alike: a failed exchange must not be
    // handed to every later caller for the rest of the session.
    _credentialsInFlight = null;
  }
}

export function hasValidAwsCredentials() {
  const awsCredentials = getAwsCredentials();
  if (
    awsCredentials?.accessKeyId == null ||
    awsCredentials?.secretAccessKey == null ||
    awsCredentials?.sessionToken == null ||
    awsCredentials?.expiration == null
  ) {
    return false;
  }

  // Add a 15-minute buffer before expiration
  const bufferTime = 15 * 60 * 1000; // 15 minutes in milliseconds
  const currentTime = new Date();
  const expirationTime = new Date(awsCredentials.expiration);
  // console.info(
  //   `${LOGGER_PREFIX} - hasValidAwsCredentials - AWS Credentials expiration: ${expirationTime.toISOString()}`
  // );

  return currentTime.getTime() + bufferTime < expirationTime.getTime();
}
