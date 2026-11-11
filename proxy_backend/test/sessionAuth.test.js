// The server-side sign-in (AUTH_MODE=bff) against a fake Ping: real RS256 ID tokens, the client secret checked
// in the Authorization header, renewals that work, are refused or cannot reach Ping.
import { test } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import { loadConfig } from "../src/config.js";
import { CLOSE_CODES } from "../src/server.js";
import { SESSION_COOKIE, SIGN_IN_COOKIE, createSealer, parseCookies } from "../src/session.js";
import { createSessionAuth } from "../src/sessionAuth.js";
import { createOidcClient } from "../src/services/oidcClient.js";
import { createSecretSource } from "../src/services/secrets.js";
import { createTestSignIn } from "../src/services/testSignIn.js";
import { ALLOWED_ORIGIN, end, runClient, silentLogger, start, startTestServer, testConfig } from "./helpers.js";

const PING = "https://sso.example.com";
const CLIENT_ID = "v2v.client";
const SECRET = "s3cret value+/=";
const KEY_1 = "session-key-one-0123456789abcdefghij";
const KEY_2 = "session-key-two-0123456789abcdefghij";
const MINUTE = 60_000;
const { privateKey, publicKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
const JWKS = { keys: [{ ...publicKey.export({ format: "jwk" }), kid: "k1", alg: "RS256", use: "sig" }] };
const PAGE = { "x-v2v-request": "1" };

const bffEnv = (extra = {}) => ({
  AUTH_MODE: "bff",
  SESSION_KEY_SECRET_ID: "v2v/session-key",
  OIDC_ISSUER: PING,
  OIDC_CLIENT_ID: CLIENT_ID,
  OIDC_CLIENT_SECRET_ID: "v2v/client-secret",
  OIDC_REDIRECT_URI: ALLOWED_ORIGIN,
  OIDC_AUTHORIZATION_ENDPOINT: `${PING}/as/authorization.oauth2`,
  OIDC_TOKEN_ENDPOINT: `${PING}/as/token.oauth2`,
  OIDC_JWKS_URI: `${PING}/pf/JWKS`,
  OIDC_REVOCATION_ENDPOINT: `${PING}/as/revoke_token.oauth2`,
  OIDC_END_SESSION_ENDPOINT: `${PING}/idp/startSLO.ping`,
  OIDC_USERINFO_ENDPOINT: `${PING}/idp/userinfo.openid`,
  ...extra,
});

const base64url = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
function idToken(claims = {}) {
  const now = Math.floor(Date.now() / 1000);
  const data = `${base64url({ alg: "RS256", typ: "JWT", kid: "k1" })}.${base64url({ iss: PING, aud: CLIENT_ID, sub: "agent1", iat: now, exp: now + 300, ...claims })}`;
  return `${data}.${sign("sha256", Buffer.from(data), privateKey).toString("base64url")}`;
}
const formEncode = (value) => encodeURIComponent(value).replace(/%20/g, "+");
const json = (status, body) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

/** Ping's token, revocation and userinfo endpoints, as a fetch function. */
function fakePing() {
  const ping = { calls: [], secret: SECRET, nonce: null, idClaims: {}, userinfo: { sub: "agent1" }, refresh: "ok", refreshClaims: {}, refreshes: 0 };
  ping.fetch = async (url, init = {}) => {
    const path = new URL(url).pathname;
    const form = init.body ? Object.fromEntries(new URLSearchParams(init.body)) : {};
    ping.calls.push({ path, headers: init.headers ?? {}, form });
    const clientOk = init.headers?.Authorization === `Basic ${Buffer.from(`${formEncode(CLIENT_ID)}:${formEncode(ping.secret)}`).toString("base64")}`;
    if (path === "/as/token.oauth2") {
      if (!clientOk) return json(401, { error: "invalid_client", error_description: "Invalid client or client credentials." });
      if (form.grant_type === "authorization_code") {
        return json(200, { access_token: "at-1", refresh_token: "rt-1", token_type: "Bearer", id_token: idToken({ nonce: ping.nonce, ...ping.idClaims }) });
      }
      if (ping.refresh === "down") throw new TypeError("fetch failed");
      if (ping.refresh === "refused") return json(400, { error: "invalid_grant", error_description: "unknown, invalid, or expired refresh token" });
      ping.refreshes++;
      return json(200, { access_token: `at-r${ping.refreshes}`, refresh_token: `rt-r${ping.refreshes}`, id_token: idToken(ping.refreshClaims) });
    }
    if (path === "/as/revoke_token.oauth2") return clientOk ? new Response("", { status: 200 }) : json(401, { error: "invalid_client" });
    if (path === "/idp/userinfo.openid") return json(200, ping.userinfo);
    return json(404, {});
  };
  return ping;
}

function request(url, { method = "GET", headers = {}, body } = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request(url, { method, headers }, (res) => {
      const chunks = [];
      res.on("data", (chunk) => chunks.push(chunk));
      res.on("end", () => {
        const text = Buffer.concat(chunks).toString("utf8");
        let parsed = null;
        try {
          parsed = JSON.parse(text);
        } catch {
          // not JSON
        }
        resolve({ status: res.statusCode, headers: res.headers, json: parsed });
      });
    });
    req.on("error", reject);
    if (body) req.write(body);
    req.end();
  });
}

/** "name=value" of a cookie the response sets, or undefined. */
const cookieSet = (response, name) => (response.headers["set-cookie"] ?? []).find((value) => value.startsWith(`${name}=`));
const cookiePair = (response, name) => cookieSet(response, name)?.split(";")[0];

async function setup({ env = {}, testSignIn = null } = {}) {
  const config = testConfig(bffEnv(env));
  const clock = { now: Date.now() };
  const ping = fakePing();
  const keys = { values: [KEY_1] };
  const clientSecret = { current: SECRET, next: SECRET, refreshed: 0, async refresh() { this.refreshed++; this.current = this.next; } };
  const sessionAuth = createSessionAuth({
    settings: config.bff,
    oidc: createOidcClient(config.bff.oidc, { clientSecret, fetchImpl: ping.fetch, jwks: JWKS }),
    sealer: createSealer({ keys: () => keys.values }),
    testSignIn,
    logger: silentLogger,
    now: () => clock.now,
  });
  const server = await startTestServer({ config, sessionAuth, testSignIn });
  return { server, ping, clock, keys, clientSecret };
}

/** /auth/login, then Ping's redirect back with a code. */
async function signIn({ server, ping }, { state } = {}) {
  const login = await request(`${server.httpUrl}/auth/login`);
  const authorize = new URL(login.headers.location);
  ping.nonce = authorize.searchParams.get("nonce");
  const back = await request(`${server.httpUrl}/?code=code-1&state=${state ?? authorize.searchParams.get("state")}`, {
    headers: { cookie: cookiePair(login, SIGN_IN_COOKIE) },
  });
  return { login, authorize, back, cookie: cookiePair(back, SESSION_COOKIE) };
}

test("Session cookie: sealed and opened, bound to its name, rejected when changed or from an unknown key", () => {
  const keys = { values: [KEY_1] };
  const sealer = createSealer({ keys: () => keys.values });
  const value = sealer.seal(SESSION_COOKIE, { v: 1, sub: "agent1" });
  assert.deepEqual(sealer.open(SESSION_COOKIE, value), { payload: { v: 1, sub: "agent1" }, stale: false });
  assert.equal(sealer.open(SIGN_IN_COOKIE, value), null, "one kind of cookie cannot be used as the other");
  const parts = value.split(".");
  const flipped = Buffer.from(parts[3], "base64url");
  flipped[0] ^= 1;
  assert.equal(sealer.open(SESSION_COOKIE, [...parts.slice(0, 3), flipped.toString("base64url")].join(".")), null);
  assert.equal(sealer.open(SESSION_COOKIE, "v1.unknown.aaaa.bbbb"), null);
  // Rotation: a new current key still opens cookies sealed with the previous one, and says they are stale.
  keys.values = [KEY_2, KEY_1];
  assert.deepEqual(sealer.open(SESSION_COOKIE, value), { payload: { v: 1, sub: "agent1" }, stale: true });
  keys.values = [KEY_2];
  assert.equal(sealer.open(SESSION_COOKIE, value), null);
  keys.values = [];
  assert.equal(sealer.ready, false);
  assert.throws(() => sealer.seal(SESSION_COOKIE, {}), /Session key not loaded/);
  assert.deepEqual([...parseCookies("a=1; b=x=y; a=2")], [["a", "1"], ["b", "x=y"]]);
});

test("Secrets: reads the current and previous versions, and keeps the last values when a read fails", async () => {
  const client = {
    values: { AWSCURRENT: "new", AWSPREVIOUS: "old" },
    fail: false,
    async send(command) {
      if (this.fail) throw Object.assign(new Error("down"), { name: "InternalServiceError" });
      const value = this.values[command.input.VersionStage];
      if (value === undefined) throw Object.assign(new Error("no such version"), { name: "ResourceNotFoundException" });
      return { SecretString: value };
    },
  };
  const source = createSecretSource({ client, secretId: "v2v/session-key", withPrevious: true, label: "session key", logger: silentLogger });
  assert.equal(await source.refresh(), true);
  assert.deepEqual([source.current, source.previous], ["new", "old"]);
  client.values = { AWSCURRENT: "only" };
  await source.refresh();
  assert.deepEqual([source.current, source.previous], ["only", null]);
  client.fail = true;
  assert.equal(await source.refresh(), true);
  assert.equal(source.current, "only");
});

test("Sign-in: /auth/login sends the browser to Ping with PKCE, state and nonce, in a sign-in cookie", async () => {
  const ctx = await setup();
  const login = await request(`${ctx.server.httpUrl}/auth/login`);
  assert.equal(login.status, 303);
  const authorize = new URL(login.headers.location);
  assert.equal(`${authorize.origin}${authorize.pathname}`, `${PING}/as/authorization.oauth2`);
  const params = Object.fromEntries(authorize.searchParams);
  assert.equal(params.client_id, CLIENT_ID);
  assert.equal(params.redirect_uri, ALLOWED_ORIGIN);
  assert.equal(params.response_type, "code");
  assert.equal(params.scope, "openid");
  assert.equal(params.code_challenge_method, "S256");
  assert.ok(params.state.length >= 20 && params.nonce.length >= 20 && params.code_challenge.length === 43);
  const cookie = cookieSet(login, SIGN_IN_COOKIE);
  assert.match(cookie, /^__Host-Http-v2v-signin=v1\./);
  assert.match(cookie, /; Path=\/; Secure; HttpOnly; SameSite=Lax; Max-Age=600$/);
  await ctx.server.close();
});

test("Sign-in: the code is swapped with the secret in the header and PKCE; the session cookie is set and opens /ws and /api", async () => {
  const ctx = await setup();
  const { authorize, back, cookie } = await signIn(ctx);
  assert.equal(back.status, 303);
  assert.equal(back.headers.location, "/");
  assert.match(cookieSet(back, SESSION_COOKIE), /; Path=\/; Secure; HttpOnly; SameSite=Strict; Max-Age=43200$/);
  assert.match(cookieSet(back, SIGN_IN_COOKIE), /Max-Age=0$/, "the sign-in cookie is used once");

  const exchange = ctx.ping.calls.find((call) => call.form.grant_type === "authorization_code");
  assert.equal(exchange.form.code, "code-1");
  assert.equal(exchange.form.redirect_uri, ALLOWED_ORIGIN);
  assert.equal(createHash("sha256").update(exchange.form.code_verifier).digest("base64url"), authorize.searchParams.get("code_challenge"));
  assert.equal(exchange.form.client_secret, undefined, "the secret is never sent in the body");
  assert.equal(JSON.stringify(back.headers).includes("rt-1"), false, "no token reaches the browser");

  const session = await request(`${ctx.server.httpUrl}/auth/session`, { headers: { ...PAGE, cookie } });
  assert.equal(session.status, 200);
  assert.equal(session.json.signedIn, true);
  assert.equal(session.json.test, false);
  assert.equal(session.json.expiresAt, ctx.clock.now + 12 * 60 * MINUTE);

  const ws = await runClient(ctx.server.wsUrl, [JSON.stringify({ type: "auth" }), start("nova"), end()], { headers: { cookie } });
  assert.equal(ws.code, CLOSE_CODES.NORMAL);
  assert.deepEqual(ws.messages[0], { type: "ready" });
  const mode = await request(`${ctx.server.httpUrl}/api/translation-mode`, { headers: { ...PAGE, cookie } });
  assert.deepEqual([mode.status, mode.json], [200, { forceBackup: false }]);
  await ctx.server.close();
});

test("Sign-in: no cookie, no request header or a forged cookie gets no access", async () => {
  const ctx = await setup();
  const { cookie } = await signIn(ctx);
  assert.equal((await request(`${ctx.server.httpUrl}/auth/session`, { headers: PAGE })).status, 401);
  assert.equal((await request(`${ctx.server.httpUrl}/auth/session`, { headers: { cookie } })).status, 403, "the request header is required");
  assert.equal((await request(`${ctx.server.httpUrl}/api/translation-mode`, { headers: { cookie } })).status, 403);
  const forged = `${SESSION_COOKIE}=v1.${"x".repeat(8)}.aaaa.bbbbbbbbbbbbbbbbbbbbbbbb`;
  const rejected = await request(`${ctx.server.httpUrl}/auth/session`, { headers: { ...PAGE, cookie: forged } });
  assert.equal(rejected.status, 401);
  assert.match(cookieSet(rejected, SESSION_COOKIE), /Max-Age=0$/);
  const ws = await runClient(ctx.server.wsUrl, [JSON.stringify({ type: "auth" }), start("nova")]);
  assert.equal(ws.code, CLOSE_CODES.UNAUTHORIZED);
  await ctx.server.close();
});

test("Sign-in: an answer that does not match the browser's sign-in, or a Ping that refuses the code, ends on an error page", async () => {
  const ctx = await setup();
  const wrongState = await signIn(ctx, { state: "not-the-state" });
  assert.equal(wrongState.cookie, undefined);
  assert.match(wrongState.back.headers.location, /^\/\?error=sign_in_failed&error_description=/);
  ctx.ping.secret = "a different secret";
  ctx.clientSecret.next = SECRET; // the secret in Secrets Manager has not changed: no second try helps
  const refused = await signIn(ctx);
  assert.equal(refused.cookie, undefined);
  assert.match(new URL(refused.back.headers.location, ALLOWED_ORIGIN).searchParams.get("error_description"), /did not accept the V2V server's credentials/);
  assert.equal(ctx.clientSecret.refreshed, 1, "an invalid_client reads the secret again once");
  await ctx.server.close();
});

test("Sign-in: after a secret rotation, Ping's invalid_client reads the new secret at once and the sign-in works", async () => {
  const ctx = await setup();
  ctx.ping.secret = "rotated secret";
  ctx.clientSecret.next = "rotated secret";
  const { cookie } = await signIn(ctx);
  assert.ok(cookie);
  assert.equal(ctx.clientSecret.refreshed, 1);
  await ctx.server.close();
});

test("Sign-in: with allowed groups, the group comes from the ID token or else from userinfo", async () => {
  const ctx = await setup({ env: { OIDC_GROUP_CLAIM: "groups", ALLOWED_GROUPS: "V2V-Agents" } });
  ctx.ping.idClaims = { groups: ["Other", "V2V-Agents"] };
  assert.ok((await signIn(ctx)).cookie);
  ctx.ping.idClaims = {};
  ctx.ping.userinfo = { sub: "agent1", groups: "V2V-Agents" };
  assert.ok((await signIn(ctx)).cookie);
  ctx.ping.userinfo = { sub: "agent1", groups: ["Other"] };
  const denied = await signIn(ctx);
  assert.equal(denied.cookie, undefined);
  assert.match(denied.back.headers.location, /^\/\?error=access_denied&/);
  await ctx.server.close();
});

test("Renewal: every 30 minutes /auth/session renews with Ping; a refusal ends the session, an outage does not", async () => {
  const ctx = await setup();
  let { cookie } = await signIn(ctx);
  const session = () => request(`${ctx.server.httpUrl}/auth/session`, { headers: { ...PAGE, cookie } });

  ctx.clock.now += 10 * MINUTE;
  assert.equal((await session()).headers["set-cookie"], undefined, "no renewal before it is due");
  assert.equal(ctx.ping.refreshes, 0);

  ctx.clock.now += 25 * MINUTE;
  const renewed = await session();
  assert.equal(renewed.status, 200);
  assert.equal(ctx.ping.refreshes, 1);
  const call = ctx.ping.calls.findLast((c) => c.form.grant_type === "refresh_token");
  assert.equal(call.form.refresh_token, "rt-1");
  cookie = cookiePair(renewed, SESSION_COOKIE);
  assert.equal(renewed.json.validUntil, ctx.clock.now + 60 * MINUTE);

  // Ping cannot be reached: the session carries on, and the renewal is tried again 5 minutes later.
  ctx.clock.now += 31 * MINUTE;
  ctx.ping.refresh = "down";
  const outage = await session();
  assert.equal(outage.status, 200);
  cookie = cookiePair(outage, SESSION_COOKIE);
  assert.equal(outage.json.validUntil, ctx.clock.now + 35 * MINUTE);

  // Ping refuses (user disabled, sign-in revoked): signed out, cookie deleted, no more connections.
  ctx.clock.now += 6 * MINUTE;
  ctx.ping.refresh = "refused";
  const ended = await session();
  assert.deepEqual([ended.status, ended.json.signedIn], [401, false]);
  assert.match(cookieSet(ended, SESSION_COOKIE), /Max-Age=0$/);
  const lastRefresh = ctx.ping.calls.findLast((c) => c.form.grant_type === "refresh_token");
  assert.equal(lastRefresh.form.refresh_token, "rt-r1", "the renewed refresh token is used");
  await ctx.server.close();
});

test("Renewal: a session that is not renewed in time cannot open connections until /auth/session renews it", async () => {
  const ctx = await setup();
  const { cookie } = await signIn(ctx);
  ctx.clock.now += 61 * MINUTE; // past the due check plus one interval, e.g. a laptop asleep
  const ws = await runClient(ctx.server.wsUrl, [JSON.stringify({ type: "auth" }), start("nova")], { headers: { cookie } });
  assert.equal(ws.code, CLOSE_CODES.UNAUTHORIZED);
  const renewed = await request(`${ctx.server.httpUrl}/auth/session`, { headers: { ...PAGE, cookie } });
  assert.equal(renewed.status, 200);
  const again = await runClient(ctx.server.wsUrl, [JSON.stringify({ type: "auth" }), start("nova"), end()], { headers: { cookie: cookiePair(renewed, SESSION_COOKIE) } });
  assert.equal(again.code, CLOSE_CODES.NORMAL);
  await ctx.server.close();
});

test("Renewal: a user removed from the allowed group loses the session at the next renewal", async () => {
  const ctx = await setup({ env: { OIDC_GROUP_CLAIM: "groups", ALLOWED_GROUPS: "V2V-Agents" } });
  ctx.ping.idClaims = { groups: ["V2V-Agents"] };
  const { cookie } = await signIn(ctx);
  ctx.clock.now += 31 * MINUTE;
  ctx.ping.refreshClaims = { groups: ["Other"] };
  const ended = await request(`${ctx.server.httpUrl}/auth/session`, { headers: { ...PAGE, cookie } });
  assert.equal(ended.status, 401);
  await ctx.server.close();
});

test("Session key rotation: a cookie sealed with the previous key still works and is sealed again; after two rotations it does not", async () => {
  const ctx = await setup();
  const { cookie } = await signIn(ctx);
  ctx.keys.values = [KEY_2, KEY_1];
  const resealed = await request(`${ctx.server.httpUrl}/auth/session`, { headers: { ...PAGE, cookie } });
  assert.equal(resealed.status, 200);
  const fresh = cookiePair(resealed, SESSION_COOKIE);
  assert.ok(fresh && fresh !== cookie);
  ctx.keys.values = ["session-key-three-0123456789abcdefgh", KEY_2];
  assert.equal((await request(`${ctx.server.httpUrl}/auth/session`, { headers: { ...PAGE, cookie } })).status, 401);
  assert.equal((await request(`${ctx.server.httpUrl}/auth/session`, { headers: { ...PAGE, cookie: fresh } })).status, 200);
  await ctx.server.close();
});

test("Sign-out: revokes the refresh token with the secret, deletes the cookie and returns Ping's sign-out address", async () => {
  const ctx = await setup();
  const { cookie } = await signIn(ctx);
  assert.equal((await request(`${ctx.server.httpUrl}/auth/logout`, { method: "POST", headers: { cookie } })).status, 403);
  const out = await request(`${ctx.server.httpUrl}/auth/logout`, { method: "POST", headers: { ...PAGE, cookie } });
  assert.equal(out.status, 200);
  const revoke = ctx.ping.calls.find((call) => call.path === "/as/revoke_token.oauth2");
  assert.deepEqual(revoke.form, { token: "rt-1", token_type_hint: "refresh_token" });
  const logoutUrl = new URL(out.json.logoutUrl);
  assert.equal(`${logoutUrl.origin}${logoutUrl.pathname}`, `${PING}/idp/startSLO.ping`);
  assert.equal(logoutUrl.searchParams.get("post_logout_redirect_uri"), ALLOWED_ORIGIN);
  assert.match(cookieSet(out, SESSION_COOKIE), /Max-Age=0$/);
  await ctx.server.close();
});

test("Test sign-in (bff): the password gives a session cookie, which ends when the password changes", async () => {
  const secrets = { value: "test-password-1", async send() { return { SecretString: this.value }; } };
  const testSignIn = createTestSignIn({ secrets, secretId: "v2v/poc/test-sign-in", logger: silentLogger });
  await testSignIn.start();
  testSignIn.stop();
  const ctx = await setup({ testSignIn });
  const post = (headers, password = "test-password-1") =>
    request(`${ctx.server.httpUrl}/api/test-sign-in`, { method: "POST", headers: { "content-type": "application/json", ...headers }, body: JSON.stringify({ name: "Tester", password }) });
  assert.equal((await post({})).status, 403, "the request header is required");
  assert.equal((await post(PAGE, "wrong-password-x")).status, 401);
  const ok = await post(PAGE);
  assert.equal(ok.status, 200);
  assert.equal(ok.json.test, true);
  const cookie = cookiePair(ok, SESSION_COOKIE);
  const ws = await runClient(ctx.server.wsUrl, [JSON.stringify({ type: "auth" }), start("nova"), end()], { headers: { cookie } });
  assert.equal(ws.code, CLOSE_CODES.NORMAL);
  const out = await request(`${ctx.server.httpUrl}/auth/logout`, { method: "POST", headers: { ...PAGE, cookie } });
  assert.equal(out.json.logoutUrl, "/", "a tester signs out back to the app, not to Ping");

  secrets.value = "test-password-2";
  await testSignIn.refresh();
  assert.equal((await request(`${ctx.server.httpUrl}/auth/session`, { headers: { ...PAGE, cookie } })).status, 401);
  await ctx.server.close();
});

test("Ping unreachable: the error names the network cause (name lookup, refused, timeout) and the host", async () => {
  const config = testConfig(bffEnv());
  const lookupFailed = Object.assign(new TypeError("fetch failed"), {
    cause: Object.assign(new Error("getaddrinfo ENOTFOUND sso.example.com"), { code: "ENOTFOUND" }),
  });
  const client = createOidcClient(config.bff.oidc, {
    clientSecret: { current: SECRET, refresh: async () => {} },
    fetchImpl: async () => {
      throw lookupFailed;
    },
    jwks: JWKS,
  });
  await assert.rejects(client.exchangeCode({ code: "c", codeVerifier: "v", nonce: "n" }), {
    code: "unreachable",
    message: "The identity provider could not be reached (TypeError: ENOTFOUND getaddrinfo ENOTFOUND sso.example.com) at sso.example.com",
  });
});

test("Config: bff mode needs the session key; Ping settings are all-or-nothing, https, and the site's root as redirect URI", () => {
  const core = { BEDROCK_REGION: "us-east-1", NOVA_MODEL_ID: "m", AUTH_MODE: "bff" };
  assert.throws(() => loadConfig(core), /SESSION_KEY_SECRET_ID/);
  const testOnly = loadConfig({ ...core, SESSION_KEY_SECRET_ID: "k" });
  assert.deepEqual(testOnly.bff.oidc, { configured: false });
  assert.equal(testOnly.bff.sessionMs, 12 * 60 * MINUTE);
  assert.equal(testOnly.bff.checkMs, 30 * MINUTE);
  const full = bffEnv();
  delete full.OIDC_TOKEN_ENDPOINT;
  assert.throws(() => loadConfig({ ...core, ...full }), /required too: OIDC_TOKEN_ENDPOINT/);
  assert.throws(() => loadConfig({ ...core, ...bffEnv({ ALLOWED_GROUPS: "V2V-Agents" }) }), /required too: OIDC_GROUP_CLAIM/);
  assert.throws(() => loadConfig({ ...core, ...bffEnv({ OIDC_TOKEN_ENDPOINT: "http://sso.example.com/token" }) }), /OIDC_TOKEN_ENDPOINT must be an https URL/);
  assert.throws(() => loadConfig({ ...core, ...bffEnv({ OIDC_REDIRECT_URI: `${ALLOWED_ORIGIN}/callback` }) }), /site's root address/);
  const config = loadConfig({ ...core, ...bffEnv({ SESSION_HOURS: "10", SESSION_CHECK_MINUTES: "15" }) });
  assert.equal(config.bff.oidc.scope, "openid");
  assert.equal(config.bff.oidc.postLogoutRedirectUri, ALLOWED_ORIGIN);
  assert.equal(config.bff.sessionMs, 10 * 60 * MINUTE);
  assert.equal(config.bff.checkMs, 15 * MINUTE);
  assert.equal(config.oidc, null);
});
