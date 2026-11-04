import { test } from "node:test";
import assert from "node:assert/strict";
import { generateKeyPairSync, sign } from "node:crypto";
import { JwtExpiredError, JwtInvalidAudienceError, JwtInvalidIssuerError, JwtInvalidSignatureError } from "aws-jwt-verify/error";
import { createOidcVerifier, createRejectingVerifier } from "../src/auth.js";
import { loadConfig } from "../src/config.js";
import { CLOSE_CODES } from "../src/server.js";
import { auth, end, runClient, start, startTestServer } from "./helpers.js";

const ISSUER = "https://sso.example.com";
const JWKS_URI = `${ISSUER}/pf/JWKS`;
const { privateKey, publicKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
const JWKS = { keys: [{ ...publicKey.export({ format: "jwk" }), kid: "k1", alg: "RS256", use: "sig" }] };

const base64url = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
/** An RS256 access token from ISSUER for audience "v2v", user "agent1", valid 10 minutes, plus `claims`. */
function accessToken(claims = {}, { key = privateKey } = {}) {
  const now = Math.floor(Date.now() / 1000);
  const data = `${base64url({ alg: "RS256", typ: "JWT", kid: "k1" })}.${base64url({ iss: ISSUER, aud: "v2v", sub: "agent1", iat: now, exp: now + 600, ...claims })}`;
  return `${data}.${sign("sha256", Buffer.from(data), key).toString("base64url")}`;
}
const oidc = (overrides = {}) => ({ issuer: ISSUER, audience: "v2v", jwksUri: JWKS_URI, groupClaim: "groups", allowedGroups: [], ...overrides });

test("OIDC: accepts a valid access token and returns the user and expiry", async () => {
  const identity = await createOidcVerifier(oidc(), { jwks: JWKS }).verify(accessToken());
  assert.equal(identity.userId, "agent1");
  assert.ok(identity.expiresAt > Date.now() + 500_000);
});

test("OIDC: rejects a wrong signature, issuer or audience, an expired token and a token without sub", async () => {
  const verifier = createOidcVerifier(oidc(), { jwks: JWKS });
  const otherKey = generateKeyPairSync("rsa", { modulusLength: 2048 }).privateKey;
  await assert.rejects(verifier.verify(accessToken({}, { key: otherKey })), JwtInvalidSignatureError);
  await assert.rejects(verifier.verify(accessToken({ iss: "https://evil.example.com" })), JwtInvalidIssuerError);
  await assert.rejects(verifier.verify(accessToken({ aud: "another-app" })), JwtInvalidAudienceError);
  await assert.rejects(verifier.verify(accessToken({ exp: Math.floor(Date.now() / 1000) - 60 })), JwtExpiredError);
  await assert.rejects(verifier.verify(accessToken({ sub: undefined })), { name: "MissingClaimError" });
});

test("OIDC: with allowed groups, the group claim must name one of them, as a list or a single value", async () => {
  const leads = "CN=V2V Leads,OU=Groups,DC=corp";
  const verifier = createOidcVerifier(oidc({ allowedGroups: ["V2V-Agents", leads] }), { jwks: JWKS });
  assert.equal((await verifier.verify(accessToken({ groups: ["Other", "V2V-Agents"] }))).userId, "agent1");
  assert.equal((await verifier.verify(accessToken({ groups: leads }))).userId, "agent1");
  await assert.rejects(verifier.verify(accessToken({ groups: ["Other"] })), { name: "GroupNotAllowedError" });
  // Values are compared whole, never split.
  await assert.rejects(verifier.verify(accessToken({ groups: "V2V-Agents,Other" })), { name: "GroupNotAllowedError" });
  await assert.rejects(verifier.verify(accessToken()), { name: "GroupNotAllowedError" });
});

test("OIDC: before the identity provider is configured, every token is rejected", async () => {
  const verifier = createRejectingVerifier();
  await verifier.hydrate();
  await assert.rejects(verifier.verify(accessToken()), { name: "AuthNotConfiguredError" });
});

test("OIDC: the WebSocket accepts a valid access token and closes 4401 for a user outside the allowed groups", async () => {
  const server = await startTestServer({ verifier: createOidcVerifier(oidc({ allowedGroups: ["V2V-Agents"] }), { jwks: JWKS }) });
  const ok = await runClient(server.wsUrl, [auth(accessToken({ groups: ["V2V-Agents"] })), start("nova"), end()]);
  assert.equal(ok.code, CLOSE_CODES.NORMAL);
  assert.deepEqual(ok.messages[0], { type: "ready" });
  const denied = await runClient(server.wsUrl, [auth(accessToken({ groups: ["Other"] })), start("nova")]);
  assert.equal(denied.code, CLOSE_CODES.UNAUTHORIZED);
  await server.close();
});

test("Config: without an issuer every token is rejected, and a half-filled OIDC client fails startup", () => {
  const env = { BEDROCK_REGION: "us-east-1", NOVA_MODEL_ID: "m" };
  const client = { OIDC_ISSUER: ISSUER, OIDC_AUDIENCE: "v2v", OIDC_JWKS_URI: JWKS_URI };
  assert.deepEqual(loadConfig(env).oidc, { configured: false });
  assert.throws(() => loadConfig({ ...env, OIDC_ISSUER: ISSUER }), /required too: OIDC_AUDIENCE, OIDC_JWKS_URI/);
  assert.throws(() => loadConfig({ ...env, ...client, ALLOWED_GROUPS: "V2V-Agents" }), /required too: OIDC_GROUP_CLAIM/);
  assert.throws(() => loadConfig({ ...env, ...client, OIDC_JWKS_URI: "http://sso.example.com/pf/JWKS" }), /must be an https URL/);
  const config = loadConfig({ ...env, ...client, OIDC_GROUP_CLAIM: "groups", ALLOWED_GROUPS: "V2V-Agents" });
  assert.deepEqual(config.oidc, { configured: true, issuer: ISSUER, audience: "v2v", jwksUri: JWKS_URI, groupClaim: "groups", allowedGroups: ["V2V-Agents"] });
  // The Region and the model are always required.
  assert.throws(() => loadConfig({ ...client }), /Missing required environment variables: BEDROCK_REGION, NOVA_MODEL_ID/);
});
