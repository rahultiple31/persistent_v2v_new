// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import { AUTH_CONFIG } from "../config";
import { LOGGER_PREFIX } from "../constants";
import {
  LOGIN_PATH,
  checkSession,
  serverLogout,
  serverSessionAuth,
  sessionExpiresAt,
  setSession,
  startSessionPolling,
} from "./serverSession";

// "bff" (server-side sign-in): the proxy signs the agent in and keeps the tokens (utils/serverSession.js);
// the functions below hand over to it, and the token code is not used.
const SERVER_SIDE = AUTH_CONFIG.mode === "bff";

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

// ── Identity provider endpoints ─────────────────────────────────────────────
//
// From the settings when the authorization and token endpoints are given, otherwise from the identity
// provider's discovery document, read once per page load.

let endpointsPromise = null;

function getEndpoints() {
  endpointsPromise ??= resolveEndpoints().catch((error) => {
    endpointsPromise = null; // try again next time
    throw error;
  });
  return endpointsPromise;
}

async function resolveEndpoints() {
  if (!AUTH_CONFIG.issuer || !AUTH_CONFIG.clientId) {
    throw new Error("Sign-in is not set up yet: no identity provider is configured for this site.");
  }
  if (AUTH_CONFIG.authorizationEndpoint && AUTH_CONFIG.tokenEndpoint) {
    return {
      authorization: AUTH_CONFIG.authorizationEndpoint,
      token: AUTH_CONFIG.tokenEndpoint,
      revocation: AUTH_CONFIG.revocationEndpoint,
      endSession: AUTH_CONFIG.endSessionEndpoint,
    };
  }
  const response = await fetch(`${AUTH_CONFIG.issuer.replace(/\/+$/, "")}/.well-known/openid-configuration`);
  if (!response.ok) throw new Error(`Identity provider discovery failed (HTTP ${response.status})`);
  const metadata = await response.json();
  // OpenID Connect Discovery: the document must name exactly the issuer it was requested for.
  if (metadata.issuer !== AUTH_CONFIG.issuer) {
    throw new Error(`Identity provider discovery names issuer ${metadata.issuer}, expected ${AUTH_CONFIG.issuer}`);
  }
  if (!metadata.authorization_endpoint || !metadata.token_endpoint) throw new Error("Identity provider discovery has no authorization or token endpoint");
  return {
    authorization: metadata.authorization_endpoint,
    token: metadata.token_endpoint,
    revocation: AUTH_CONFIG.revocationEndpoint || metadata.revocation_endpoint,
    endSession: AUTH_CONFIG.endSessionEndpoint || metadata.end_session_endpoint,
  };
}

// PKCE verifier and state for the sign-in in progress. They live in this tab's sessionStorage from the
// redirect to the identity provider until the redirect back, and are removed as soon as they are used.
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

// Generate the sign-in URL.
//  - PKCE (S256): the identity provider only exchanges the code together with the verifier kept in this tab,
//    so an authorization code taken from browser history, logs or an extension is useless on its own.
//  - state: the redirect back is accepted only if it answers the sign-in this tab started, which stops a
//    forged redirect from signing the browser in as someone else (login CSRF).
export async function getLoginUrl() {
  // Server-side sign-in: the proxy makes the state, nonce and PKCE verifier and sends the browser on to Ping.
  if (SERVER_SIDE) return new URL(LOGIN_PATH, window.location.origin).href;
  const endpoints = await getEndpoints();
  // Browsers only offer the Web Crypto API (and the microphone) to HTTPS pages.
  if (!window.isSecureContext) throw new Error("Sign-in needs this page to be opened over HTTPS.");
  const verifier = randomToken(32);
  const state = randomToken(16);
  const challenge = base64Url(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier))));
  sessionStorage.setItem(PKCE_VERIFIER_KEY, verifier);
  sessionStorage.setItem(OAUTH_STATE_KEY, state);

  const params = new URLSearchParams({
    client_id: AUTH_CONFIG.clientId,
    response_type: "code",
    scope: AUTH_CONFIG.scope,
    redirect_uri: getRedirectURI(),
    state,
    code_challenge: challenge,
    code_challenge_method: "S256",
  });
  return `${endpoints.authorization}?${params.toString()}`;
}

/**
 * True when the agent is signed in at page load: with the server-side sign-in, when the proxy has a session
 * for this browser (it took the identity provider's answer itself); otherwise, when this load is the
 * redirect back from the identity provider and its code was exchanged.
 */
export async function restoreSession() {
  if (SERVER_SIDE) return (await checkSession()) === "signedIn";
  return handleRedirect();
}

// Handle the redirect back from the identity provider
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

const expiryText = (token) => {
  const exp = decodeToken(token)?.exp;
  return exp ? new Date(exp * 1000).toISOString() : "unknown";
};

// Exchange authorization code for tokens
async function getTokens(code, codeVerifier) {
  const params = new URLSearchParams({
    grant_type: "authorization_code",
    client_id: AUTH_CONFIG.clientId,
    code: code,
    redirect_uri: getRedirectURI(),
    code_verifier: codeVerifier,
  });

  const response = await fetch((await getEndpoints()).token, {
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
  // The proxy verifies the access token itself, so it must be a JWT (not an opaque reference token).
  if (!decodeToken(tokens.access_token)?.exp) throw new Error("The access token is not a JWT with an expiry");
  console.info(
    `${LOGGER_PREFIX} - getTokens - Tokens obtained, id_token expires at ${expiryText(tokens.id_token)}, access_token expires at ${expiryText(tokens.access_token)}`
  );
  return tokens;
}

// Tokens, held in this page's memory only: they are never written to disk, where malware or the next user of
// a shared PC could copy them, and they are gone when the tab closes. A reload therefore signs in again,
// which with SSO is a few automatic redirects.
let _tokens = null;
// Signed in with the temporary test sign-in (utils/testSignIn.js): no identity provider session to end.
let testSession = false;

/** Starts a session from the proxy's test sign-in: an access token, or (server-side sign-in) a cookie it set. */
export function setTestSession({ accessToken, expiresAt }) {
  testSession = true;
  if (SERVER_SIDE) {
    setSession({ expiresAt, test: true });
    return;
  }
  _tokens = { accessToken, idToken: null, refreshToken: null };
}

function setTokens(tokens) {
  _tokens = {
    accessToken: tokens.access_token,
    // A refresh response may carry no new ID or refresh token: keep the ones from sign-in.
    idToken: tokens.id_token ?? _tokens?.idToken ?? null,
    refreshToken: tokens.refresh_token ?? _tokens?.refreshToken ?? null,
  };
}

function getToken(name) {
  return _tokens?.[name] ?? null;
}

// The token whose expiry triggers a refresh: the proxy only needs the access token, and the identity provider
// may not issue a new ID token on refresh.
function sessionTokens() {
  return [getToken("accessToken")];
}

export function isTokenExpired(token) {
  if (token == null) return true;

  try {
    // Get payload from JWT token (second part between dots)
    const payload = decodeJwtPayload(token);

    // exp is in seconds, convert current time to seconds
    const currentTime = Math.floor(Date.now() / 1000);

    // Check if token has expired
    return payload.exp < currentTime;
  } catch (error) {
    console.error(`${LOGGER_PREFIX} - isTokenExpired - Error checking token expiration:`, error);
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
      client_id: AUTH_CONFIG.clientId,
      refresh_token: refreshToken,
    });

    const response = await fetch((await getEndpoints()).token, {
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
    setTokens(tokens);
    console.info(
      `${LOGGER_PREFIX} - refreshTokens - Tokens refreshed, id_token expire at ${expiryText(tokens.id_token)}, access_token expire at ${expiryText(tokens.access_token)}`
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
  return getToken("accessToken") != null && !sessionTokens().some(isTokenExpired);
}

// Get valid access token (refreshing if needed)
export async function getValidTokens() {
  // The session has already ended and sign-out is waiting for the current call to finish.
  if (pendingSignOut) return;

  if (getToken("accessToken") == null) {
    console.error(`${LOGGER_PREFIX} - getValidTokens - Not signed in`);
    endSession("not signed in");
    return;
  }

  if (sessionTokens().some(isTokenExpired)) {
    if (getToken("refreshToken") == null) {
      // The identity provider issued no refresh token: the session ends with the access token.
      endSession("access token expired, no refresh token");
      return;
    }
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

/**
 * How a request to the translation proxy proves who the agent is (utils/proxyTransport.js):
 * { token?, expiresAt, headers, credentials }. A bearer token, or with the server-side sign-in the session
 * cookie (credentials "same-origin") and the fixed request header. expiresAt: until when new connections are
 * accepted. Throws when not signed in, including after the session ended during a call.
 */
export async function getProxyAuth() {
  if (pendingSignOut) throw new Error("Not signed in: the sign-in has ended");
  if (SERVER_SIDE) return serverSessionAuth();
  const tokens = await getValidTokens();
  if (!tokens?.accessToken) throw new Error("Not signed in: no access token for the translation proxy");
  return {
    token: tokens.accessToken,
    expiresAt: (decodeToken(tokens.accessToken)?.exp ?? 0) * 1000,
    headers: { Authorization: `Bearer ${tokens.accessToken}` },
    credentials: "omit",
  };
}

// A JWT's payload: base64url-encoded UTF-8 JSON (not plain base64, which atob alone expects).
function decodeJwtPayload(token) {
  const base64 = token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/");
  const binary = atob(base64.padEnd(base64.length + ((4 - (base64.length % 4)) % 4), "="));
  return JSON.parse(new TextDecoder().decode(Uint8Array.from(binary, (char) => char.charCodeAt(0))));
}

// Helper to decode token payload
export function decodeToken(token) {
  if (token == null) return null;
  try {
    return decodeJwtPayload(token);
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

/** Starts the background token refresh timer (server-side sign-in: the session check with the proxy). */
export function startTokenRefreshTimer() {
  if (SERVER_SIDE) {
    startSessionPolling(endSession);
    return;
  }
  const tokens = sessionTokens();
  if (tokens.some((token) => token == null)) throw new Error("Unable to startTokenRefreshTimer - No tokens available");

  const payloads = tokens.map(decodeToken);
  if (payloads.some((payload) => payload?.exp == null)) throw new Error("Unable to startTokenRefreshTimer - Error decoding tokens");

  // Refresh 4 minutes before the first token expires, or after three quarters of its lifetime if that is
  // shorter, so short-lived tokens never refresh in a tight loop.
  const refreshTime = Math.max(
    0,
    Math.min(
      ...payloads.map(({ exp, iat }) => {
        const lifetimeMs = iat ? (exp - iat) * 1000 : Infinity;
        return exp * 1000 - Date.now() - Math.min(4 * 60 * 1000, lifetimeMs / 4);
      })
    )
  );

  if (getToken("refreshToken") == null) {
    // Nothing to refresh with: end the session when the access token expires (never during a call).
    const expiresIn = Math.max(0, Math.min(...payloads.map(({ exp }) => exp * 1000 - Date.now())));
    console.info(`${LOGGER_PREFIX} - startTokenRefreshTimer - No refresh token: the session ends in ${Math.floor(expiresIn / 1000)}s`);
    setTimeout(() => endSession("access token expired, no refresh token"), expiresIn);
    return;
  }

  console.info(`${LOGGER_PREFIX} - startTokenRefreshTimer - Token refresh timer set for ${Math.floor(refreshTime / 1000)}s`);
  setTimeout(async () => {
    try {
      await refreshTokens();
      // Start new timer after refresh.
      startTokenRefreshTimer();
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
  if (SERVER_SIDE) return sessionExpiresAt();
  const idToken = getToken("idToken");
  if (!idToken) return null;
  const payload = decodeToken(idToken);
  const hours = Number(AUTH_CONFIG.refreshTokenValidityHours);
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
  if (SERVER_SIDE) {
    // The proxy ends the session and revokes the refresh token; then Ping's sign-out (or the app, for a tester).
    window.location.href = await serverLogout();
    return;
  }
  const refreshToken = getToken("refreshToken");
  const idToken = getToken("idToken");
  _tokens = null;
  if (testSession) {
    // Back to the app, which asks for the test password again (or signs in normally once it is off).
    window.location.href = getRedirectURI();
    return;
  }
  const endpoints = await getEndpoints().catch(() => null);

  // Revoke the refresh token, so a copy of it cannot mint new access tokens after sign-out. Bounded, so
  // a slow or failed request never holds up the sign-out itself.
  if (refreshToken && endpoints?.revocation) {
    try {
      await Promise.race([
        fetch(endpoints.revocation, {
          method: "POST",
          headers: { "Content-Type": "application/x-www-form-urlencoded" },
          body: new URLSearchParams({ token: refreshToken, client_id: AUTH_CONFIG.clientId }).toString(),
          keepalive: true,
        }),
        new Promise((resolve) => setTimeout(resolve, 2000)),
      ]);
    } catch (error) {
      console.warn(`${LOGGER_PREFIX} - logout - refresh token revocation failed`, error);
    }
  }

  if (!endpoints?.endSession) {
    // No sign-out endpoint known: back to the app, which starts a new sign-in.
    window.location.href = getRedirectURI();
    return;
  }
  // OpenID Connect RP-initiated logout: post_logout_redirect_uri, plus the ID token so the identity provider
  // signs out without asking.
  const params = new URLSearchParams({
    client_id: AUTH_CONFIG.clientId,
    post_logout_redirect_uri: getRedirectURI(),
    ...(idToken ? { id_token_hint: idToken } : {}),
  });
  window.location.href = `${endpoints.endSession}?${params.toString()}`;
}
