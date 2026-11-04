// The server-side sign-in (authMode "bff", proxy/src/sessionAuth.js). The proxy signs the agent in with the
// identity provider and keeps the tokens; this page only knows whether it is signed in and until when. The
// session cookie travels by itself with every request to the site (the page cannot read it), and every
// request carries the fixed header the proxy requires, which other sites cannot send.
import { LOGGER_PREFIX } from "../constants";

export const SESSION_REQUEST_HEADERS = Object.freeze({ "X-V2V-Request": "1" });
export const LOGIN_PATH = "/auth/login";
const SESSION_PATH = "/auth/session";
const LOGOUT_PATH = "/auth/logout";
// The proxy renews with the identity provider when a check is due (every 30 minutes by default). Asking
// every few minutes keeps the session inside its window, and notices a sign-in that has ended.
const POLL_MS = 5 * 60_000;
// Ask before opening a connection when the window ends this soon.
const RENEW_MARGIN_MS = 2 * 60_000;

let session = null; // { expiresAt, validUntil, test }
let pollTimer = null;
let watchingVisibility = false;
let onEnded = () => {};

/**
 * Asks the proxy whether this browser is signed in (and lets it renew the session when due).
 * @returns {Promise<"signedIn"|"signedOut"|"unknown">} unknown: the proxy could not be reached
 */
export async function checkSession() {
  let response;
  try {
    response = await fetch(SESSION_PATH, { headers: SESSION_REQUEST_HEADERS, credentials: "same-origin", cache: "no-store" });
  } catch (error) {
    console.warn(`${LOGGER_PREFIX} - checkSession - the site could not be reached`, error);
    return "unknown";
  }
  if (response.status === 401) {
    session = null;
    return "signedOut";
  }
  if (!response.ok) {
    console.warn(`${LOGGER_PREFIX} - checkSession - HTTP ${response.status}`);
    return "unknown";
  }
  const body = await response.json();
  session = { expiresAt: body.expiresAt, validUntil: body.validUntil ?? body.expiresAt, test: body.test === true };
  return "signedIn";
}

/** After the test sign-in, whose answer already says until when it lasts. */
export function setSession({ expiresAt, test }) {
  session = { expiresAt, validUntil: expiresAt, test: test === true };
}

export function sessionExpiresAt() {
  return session?.expiresAt ?? null;
}

/** Asks the proxy every few minutes, and when the page comes back into view. `ended` runs once when signed out. */
export function startSessionPolling(ended) {
  onEnded = ended;
  clearInterval(pollTimer);
  const check = async () => {
    if ((await checkSession()) === "signedOut") {
      clearInterval(pollTimer);
      onEnded("signed out by the server");
    }
  };
  pollTimer = setInterval(check, POLL_MS);
  if (!watchingVisibility) {
    watchingVisibility = true;
    document.addEventListener("visibilitychange", () => {
      if (document.visibilityState === "visible" && session) check();
    });
  }
}

/**
 * How requests to the proxy authenticate: the cookie (credentials "same-origin") plus the request header.
 * expiresAt: until when the proxy lets this session open connections without asking it first.
 */
export async function serverSessionAuth() {
  if (session && session.validUntil - Date.now() < RENEW_MARGIN_MS) {
    if ((await checkSession()) === "signedOut") onEnded("signed out by the server");
  }
  if (!session) throw new Error("Not signed in to the translation proxy");
  return { expiresAt: session.validUntil, headers: SESSION_REQUEST_HEADERS, credentials: "same-origin" };
}

/** Ends the session at the proxy. Resolves with where to go next: the identity provider's sign-out, or the app. */
export async function serverLogout() {
  clearInterval(pollTimer);
  session = null;
  try {
    const response = await fetch(LOGOUT_PATH, { method: "POST", headers: SESSION_REQUEST_HEADERS, credentials: "same-origin", cache: "no-store" });
    const body = await response.json();
    return typeof body?.logoutUrl === "string" ? body.logoutUrl : "/";
  } catch (error) {
    console.warn(`${LOGGER_PREFIX} - serverLogout - sign-out request failed`, error);
    return "/";
  }
}
