// Server-side sign-in with Ping (AUTH_MODE=bff): the "backend for frontend" pattern of the OAuth standard
// for browser-based apps (RFC 10017). The proxy is the OAuth client and keeps the tokens; the browser only
// holds an encrypted session cookie (session.js), which it sends by itself with every request to this site.
//
//   GET  /auth/login    sends the browser to Ping: authorization code flow with PKCE, state and nonce
//   GET  /?code&state   Ping sends the agent back here (the registered redirect URI is the site's root): the
//                       proxy swaps the code for tokens with the client secret, checks the ID token and the
//                       group, sets the session cookie and returns to /
//   GET  /auth/session  whether this browser is signed in; renews with Ping when a check is due
//   POST /auth/logout   ends the session, revokes the refresh token, and says where to sign out at Ping
//
// Every request the page makes carries the X-V2V-Request header (REQUEST_HEADER). Browsers only send a custom
// header to another site after a CORS preflight, which this server never allows, so no other site can send
// requests with the agent's cookie (RFC 10017, 6.1.3.3). WebSockets cannot carry custom headers; server.js
// checks the upgrade's Origin instead.
//
// Renewal: while signed in, the page asks /auth/session every few minutes. Every checkMs the proxy renews
// with Ping's refresh token, so a user who is disabled or removed from the group at Ping loses access within
// about checkMs; the session ends for good after sessionMs. If Ping cannot be reached, the session carries
// on and the renewal is tried again a few minutes later.
import { createHash, randomBytes } from "node:crypto";
import { tokenGroups } from "./auth.js";
import { errorFields } from "./logger.js";
import { SESSION_COOKIE, SIGN_IN_COOKIE, clearCookieHeader, cookieHeader, parseCookies } from "./session.js";

export const REQUEST_HEADER = "x-v2v-request";
const LOGIN_PATH = "/auth/login";
const SESSION_PATH = "/auth/session";
const LOGOUT_PATH = "/auth/logout";
const AUTH_PREFIX = "/auth/";
const SIGN_IN_MAX_AGE_MS = 10 * 60_000;
const RETRY_AFTER_FAILED_RENEWAL_MS = 5 * 60_000;
const REVOKE_WAIT_MS = 2_000;
// Browsers keep cookies up to 4096 bytes. A session that would not fit drops its refresh token (and is then
// not re-checked) rather than failing the sign-in.
const MAX_COOKIE_CHARS = 3_800;

const random = (bytes) => randomBytes(bytes).toString("base64url");
const sha256 = (text) => createHash("sha256").update(text).digest("base64url");
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms).unref?.());

class SessionError extends Error {
  constructor(name, message) {
    super(message);
    this.name = name;
  }
}

function send(res, status, body, headers = {}) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(payload),
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
    ...headers,
  });
  res.end(payload);
}

function redirect(res, location, cookies = []) {
  res.writeHead(303, { Location: location, "Cache-Control": "no-store", "Content-Length": 0, ...(cookies.length ? { "Set-Cookie": cookies } : {}) });
  res.end();
}

// The page shows "Sign-in failed: <description>" for these (main.js) and does not redirect again.
function signInErrorLocation(error, description) {
  return `/?${new URLSearchParams({ error, error_description: description })}`;
}

const SIGN_IN_ERRORS = {
  unreachable: "The V2V server could not reach the sign-in service. Try again in a few minutes; if it keeps failing, contact support.",
  client_secret_unavailable: "The V2V server could not load its sign-in credentials. Try again in a few minutes; if it keeps failing, contact support.",
  invalid_client: "The sign-in service did not accept the V2V server's credentials. Contact support.",
  invalid_grant: "The sign-in code was not accepted (it may have expired). Reload the page to sign in again.",
  invalid_id_token: "The sign-in response could not be verified. Contact support.",
  no_id_token: "The sign-in response could not be verified. Contact support.",
};

/**
 * @param {object} deps
 * @param {object} deps.settings - config.bff
 * @param {object|null} deps.oidc - services/oidcClient.js; null while Ping is not configured (test sign-in only)
 * @param {object} deps.sealer - session.js createSealer()
 * @param {object|null} [deps.testSignIn] - services/testSignIn.js
 */
export function createSessionAuth({ settings, oidc, sealer, testSignIn = null, logger, now = () => Date.now() }) {
  const { sessionMs, checkMs } = settings;
  const { allowedGroups, groupClaim } = settings.oidc.configured ? settings.oidc : { allowedGroups: [], groupClaim: null };
  // One renewal per refresh token at a time, when several requests arrive together. (Across the two tasks
  // this is not shared: if Ping hands out a new refresh token at every renewal and two renewals of one
  // session reach different tasks at the same moment, Ping may refuse the second. The page renews from one
  // place, every few minutes, so this is rare; the agent would then sign in again after the call.)
  const renewals = new Map();

  function readSession(req) {
    const value = parseCookies(req.headers.cookie).get(SESSION_COOKIE);
    if (value === undefined) return null;
    const opened = sealer.open(SESSION_COOKIE, value);
    return opened && opened.payload?.v === 1 ? opened : { payload: null, stale: false, unreadable: true };
  }

  // How long this session may open connections without a check with Ping: up to one check interval after
  // the check that is due, and never past the end of the session.
  const validUntil = (session) => (session.m === "ping" ? Math.min(session.exp, session.chk + checkMs) : session.exp);

  function sessionCookie(session) {
    let value = sealer.seal(SESSION_COOKIE, session);
    if (value.length > MAX_COOKIE_CHARS && session.rt) {
      logger.warn("refresh token too large for the session cookie: this session is not re-checked with Ping", { userId: session.sub });
      const { rt, ...rest } = session;
      session = { ...rest, chk: rest.exp };
      value = sealer.seal(SESSION_COOKIE, session);
    }
    return cookieHeader(SESSION_COOKIE, value, { maxAgeSeconds: (session.exp - now()) / 1000 });
  }

  const inAllowedGroup = (claimValue) => tokenGroups(claimValue).some((group) => allowedGroups.includes(group));

  // The user's group claim from the ID token, or else from userinfo. undefined: Ping said nothing about it.
  async function groupClaimValue(claims, accessToken, userinfo) {
    if (claims && claims[groupClaim] !== undefined) return claims[groupClaim];
    const info = userinfo ?? (accessToken ? await oidc.userinfo(accessToken) : null);
    return info?.[groupClaim];
  }

  // ── Routes ──────────────────────────────────────────────────────────────────

  function handleLogin(req, res) {
    if (!oidc) {
      return redirect(res, signInErrorLocation("sign_in_unavailable", "Sign-in with the identity provider is not set up on this server yet."));
    }
    if (!sealer.ready) {
      return redirect(res, signInErrorLocation("sign_in_unavailable", "The V2V server could not load its session key. Try again in a few minutes; if it keeps failing, contact support."));
    }
    const signIn = { state: random(16), nonce: random(16), verifier: random(32), at: now() };
    const cookie = cookieHeader(SIGN_IN_COOKIE, sealer.seal(SIGN_IN_COOKIE, signIn), { maxAgeSeconds: SIGN_IN_MAX_AGE_MS / 1000, sameSite: "Lax" });
    return redirect(res, oidc.authorizationUrl({ state: signIn.state, nonce: signIn.nonce, codeChallenge: sha256(signIn.verifier) }), [cookie]);
  }

  async function handleCallback(req, res, url) {
    const clearSignIn = clearCookieHeader(SIGN_IN_COOKIE, "Lax");
    const fail = (error, description) => redirect(res, signInErrorLocation(error, description), [clearSignIn]);
    const signIn = sealer.open(SIGN_IN_COOKIE, parseCookies(req.headers.cookie).get(SIGN_IN_COOKIE))?.payload;
    // state: the answer must belong to a sign-in this browser started (login CSRF). One use only.
    if (!signIn || signIn.state !== url.searchParams.get("state") || !(now() - signIn.at < SIGN_IN_MAX_AGE_MS)) {
      logger.warn("sign-in response rejected: no matching sign-in in this browser", { hadSignInCookie: Boolean(signIn) });
      return fail("sign_in_failed", "This sign-in did not match one started in this browser, or took longer than 10 minutes. Reload the page to sign in again.");
    }
    if (!oidc) return fail("sign_in_unavailable", "Sign-in with the identity provider is not set up on this server yet.");

    let result;
    const exchangeStartedAt = performance.now();
    try {
      result = await oidc.exchangeCode({ code: url.searchParams.get("code"), codeVerifier: signIn.verifier, nonce: signIn.nonce });
    } catch (err) {
      // durationMs: a quick failure is a refusal or a certificate problem; about 8000 is no answer at all.
      const durationMs = Math.round(performance.now() - exchangeStartedAt);
      logger.error("sign-in failed at the token exchange", { code: err?.code, status: err?.status, durationMs, ...errorFields(err) });
      return fail("sign_in_failed", SIGN_IN_ERRORS[err?.code] ?? `The sign-in could not be completed (${err?.code ?? "error"}). Contact support.`);
    }
    const { claims, accessToken, refreshToken } = result;

    // userinfo is read once at sign-in when Ping has one: its claim names go to the log below, and the groups
    // may be there rather than in the ID token. Only needed for the group check if they are not in the ID token.
    let userinfoClaims = null;
    try {
      userinfoClaims = await oidc.userinfo(accessToken);
    } catch (err) {
      logger.warn("userinfo could not be read at sign-in", { userId: claims.sub, code: err?.code, ...errorFields(err) });
    }
    let allowed = true;
    if (allowedGroups.length) {
      try {
        allowed = inAllowedGroup(await groupClaimValue(claims, accessToken, userinfoClaims));
      } catch (err) {
        logger.error("sign-in failed reading the user's groups", { userId: claims.sub, code: err?.code, ...errorFields(err) });
        return fail("sign_in_failed", SIGN_IN_ERRORS[err?.code] ?? "The sign-in could not be completed (groups). Contact support.");
      }
    }
    // Claim names only (never values), to see where Ping puts the groups when setting up the group check.
    logger.info("sign-in claims", {
      userId: claims.sub,
      idTokenClaims: Object.keys(claims).sort(),
      ...(userinfoClaims ? { userinfoClaims: Object.keys(userinfoClaims).sort() } : {}),
      refreshToken: Boolean(refreshToken),
    });
    if (!allowed) {
      logger.warn("sign-in refused: not in an allowed group", { userId: claims.sub, groupClaim });
      return fail("access_denied", "Your account is not in a group that may use V2V. Ask your manager for access.");
    }

    const at = now();
    const session = { v: 1, m: "ping", sub: claims.sub, iat: at, exp: at + sessionMs, chk: refreshToken ? at + checkMs : at + sessionMs };
    if (refreshToken) session.rt = refreshToken;
    else logger.warn("no refresh token from Ping: this session is not re-checked until it ends", { userId: claims.sub });
    logger.info("signed in", { userId: claims.sub, sessionEndsAt: new Date(session.exp).toISOString() });
    return redirect(res, "/", [sessionCookie(session), clearSignIn]);
  }

  async function renew(session) {
    const key = sha256(session.rt);
    let pending = renewals.get(key);
    if (!pending) {
      pending = (async () => {
        try {
          const result = await oidc.refresh({ refreshToken: session.rt, sub: session.sub });
          if (allowedGroups.length) {
            // Removed from the group at Ping: the session ends. Nothing said about groups: it carries on.
            const claimValue = await groupClaimValue(result.claims, result.accessToken);
            if (claimValue !== undefined && !inAllowedGroup(claimValue)) return { outcome: "ended", reason: "group" };
          }
          return { outcome: "renewed", refreshToken: result.refreshToken };
        } catch (err) {
          // invalid_grant: Ping no longer accepts this sign-in (user disabled, signed out, refresh token
          // expired or revoked). Anything else (Ping unreachable, a server-side error) is not the user's fault.
          if (err?.code === "invalid_grant" || err?.code === "invalid_id_token") return { outcome: "ended", reason: err.code };
          logger.warn("session renewal with Ping failed; trying again later", { userId: session.sub, code: err?.code, ...errorFields(err) });
          return { outcome: "retry" };
        } finally {
          renewals.delete(key);
        }
      })();
      renewals.set(key, pending);
    }
    return pending;
  }

  async function handleSession(req, res) {
    const opened = readSession(req);
    const signedOut = (reason) => send(res, 401, { signedIn: false, reason }, opened ? { "Set-Cookie": clearCookieHeader(SESSION_COOKIE) } : {});
    if (!opened?.payload) return signedOut(opened ? "unreadable" : "none");
    let session = opened.payload;
    let changed = opened.stale; // sealed with the previous key: seal it again with the current one
    if (!(session.exp > now())) return signedOut("expired");
    if (session.m === "test") {
      if (!testSignIn?.on || testSignIn.keyId !== session.tk) return signedOut("testSignInEnded");
    } else if (session.m !== "ping") {
      return signedOut("unreadable");
    } else if (session.rt && now() >= session.chk && oidc) {
      const result = await renew(session);
      if (result.outcome === "ended") {
        logger.info("session ended by Ping", { userId: session.sub, reason: result.reason });
        return signedOut("ended");
      }
      session = { ...session, rt: result.refreshToken ?? session.rt, chk: now() + (result.outcome === "renewed" ? checkMs : RETRY_AFTER_FAILED_RENEWAL_MS) };
      changed = true;
    }
    if (!(validUntil(session) > now())) return signedOut("checkOverdue");
    return send(
      res,
      200,
      { signedIn: true, test: session.m === "test", expiresAt: session.exp, validUntil: validUntil(session) },
      changed ? { "Set-Cookie": sessionCookie(session) } : {},
    );
  }

  async function handleLogout(req, res) {
    const session = readSession(req)?.payload;
    if (session?.m === "ping" && session.rt && oidc) {
      // Bounded, so a slow Ping never holds up the sign-out.
      const revoked = oidc.revoke(session.rt).catch((err) => logger.warn("refresh token revocation failed", { userId: session.sub, code: err?.code, ...errorFields(err) }));
      await Promise.race([revoked, sleep(REVOKE_WAIT_MS)]);
    }
    if (session?.sub) logger.info("signed out", { userId: session.sub, method: session.m });
    const logoutUrl = session?.m === "test" ? "/" : (oidc?.logoutUrl() ?? "/");
    return send(res, 200, { logoutUrl }, { "Set-Cookie": clearCookieHeader(SESSION_COOKIE) });
  }

  return {
    /** True when the page sent the fixed request header (CSRF defence for every fetch). */
    hasRequestHeader: (req) => req.headers[REQUEST_HEADER] === "1",

    /** Handles /auth/* and the redirect back from Ping. Returns false for every other request. */
    async handle(req, res, url) {
      const { pathname } = url;
      if (pathname === "/" && req.method === "GET" && url.searchParams.has("code") && url.searchParams.has("state")) {
        await handleCallback(req, res, url);
        return true;
      }
      if (!pathname.startsWith(AUTH_PREFIX)) return false;
      if (pathname === LOGIN_PATH) {
        if (req.method !== "GET") send(res, 405, { error: "methodNotAllowed" }, { Allow: "GET" });
        else handleLogin(req, res);
      } else if (pathname === SESSION_PATH) {
        if (req.method !== "GET") send(res, 405, { error: "methodNotAllowed" }, { Allow: "GET" });
        else if (req.headers[REQUEST_HEADER] !== "1") send(res, 403, { error: "requestHeaderMissing" });
        else await handleSession(req, res);
      } else if (pathname === LOGOUT_PATH) {
        if (req.method !== "POST") send(res, 405, { error: "methodNotAllowed" }, { Allow: "POST" });
        else if (req.headers[REQUEST_HEADER] !== "1") send(res, 403, { error: "requestHeaderMissing" });
        else await handleLogout(req, res);
      } else {
        send(res, 404, { error: "notFound" });
      }
      return true;
    },

    /**
     * The signed-in user of a request (/ws upgrade or /api), from the session cookie. No call to Ping.
     * @returns {Promise<{userId: string, expiresAt: number}>} expiresAt: until when new streams may start
     */
    async identify(req) {
      const session = readSession(req)?.payload;
      if (!session) throw new SessionError("NoSessionError", "Not signed in");
      if (!(session.exp > now())) throw new SessionError("SessionExpiredError", "The session has ended");
      if (session.m === "test") {
        if (!testSignIn?.on || testSignIn.keyId !== session.tk) throw new SessionError("TestSessionEndedError", "Test sign-in was switched off or its password changed");
      } else if (session.m !== "ping") {
        throw new SessionError("NoSessionError", "Not signed in");
      }
      const until = validUntil(session);
      if (!(until > now())) throw new SessionError("SessionCheckOverdueError", "The session must be renewed first (/auth/session)");
      return { userId: session.sub, expiresAt: until };
    },

    /** The Set-Cookie value and expiry for a test sign-in by `name` (services/testSignIn.js checked the password). */
    testSession(name) {
      if (!sealer.ready) throw new SessionError("SessionKeyUnavailableError", "Session key not loaded");
      const at = now();
      const session = { v: 1, m: "test", sub: `test:${name}`, iat: at, exp: at + testSignIn.sessionMs, chk: at + testSignIn.sessionMs, tk: testSignIn.keyId };
      return { cookie: sessionCookie(session), expiresAt: session.exp };
    },
  };
}
