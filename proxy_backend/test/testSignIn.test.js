import { test } from "node:test";
import assert from "node:assert/strict";
import { GetSecretValueCommand, SecretsManagerClient } from "@aws-sdk/client-secrets-manager";
import { CLOSE_CODES } from "../src/server.js";
import { createAwsClients } from "../src/awsClients.js";
import { loadConfig } from "../src/config.js";
import { createTestSignIn, withTestSignIn } from "../src/services/testSignIn.js";
import { auth, end, fakeVerifier, runClient, silentLogger, start, startTestServer, testConfig } from "./helpers.js";

const PASSWORD = "correct-horse-battery";
const SECRET_ID = "v2v/poc/test-sign-in";

/** A Secrets Manager fake holding one secret; null = no secret. */
function fakeSecrets(initial) {
  return {
    value: initial,
    fail: false,
    deleted: false,
    async send(command) {
      assert.ok(command instanceof GetSecretValueCommand);
      assert.equal(command.input.SecretId, SECRET_ID);
      if (this.fail) throw Object.assign(new Error("throttled"), { name: "ThrottlingException" });
      if (this.deleted) throw Object.assign(new Error("marked for deletion"), { name: "InvalidRequestException" });
      if (this.value == null) throw Object.assign(new Error("not found"), { name: "ResourceNotFoundException" });
      return { SecretString: this.value };
    },
  };
}

async function switchFor(value, opts = {}) {
  const secrets = fakeSecrets(value);
  const testSignIn = createTestSignIn({ secrets, secretId: SECRET_ID, logger: silentLogger, ...opts });
  await testSignIn.refresh();
  return { secrets, testSignIn };
}

test("test sign-in: off without a secret, with 'off', with a password under 12 characters, or a key/value secret without 'password'", async () => {
  const offValues = [null, "off", " OFF ", "short-pw", "x".repeat(11), '{"password":"off"}', '{"password":"short-pw"}', `{"pw":"${PASSWORD}"}`];
  for (const value of offValues) {
    const { testSignIn } = await switchFor(value);
    assert.equal(testSignIn.on, false, String(value));
    assert.equal(testSignIn.signIn({ password: value ?? "", name: "a" }), null);
  }
});

test("test sign-in: the password may be plaintext or the console's key/value form; 12 characters is enough", async () => {
  for (const [value, password] of [
    [PASSWORD, PASSWORD],
    [` ${PASSWORD}\n`, PASSWORD],
    [`{"password":"${PASSWORD}"}`, PASSWORD],
    [`{\n  "password": " ${PASSWORD} ",\n  "note": "testers"\n}`, PASSWORD],
    ["x".repeat(12), "x".repeat(12)],
    ["{not-json-password", "{not-json-password"],
  ]) {
    const { testSignIn } = await switchFor(value);
    assert.equal(testSignIn.on, true, value);
    assert.ok(testSignIn.signIn({ password, name: "anna" }), value);
  }
});

test("test sign-in: a warning about the secret's value is logged once, not on every read", async () => {
  const warnings = [];
  const logger = { ...silentLogger, warn: (message) => warnings.push(message) };
  const secrets = fakeSecrets("short-pw");
  const testSignIn = createTestSignIn({ secrets, secretId: SECRET_ID, logger });
  await testSignIn.refresh();
  await testSignIn.refresh();
  secrets.value = `{"pw":"${PASSWORD}"}`;
  await testSignIn.refresh();
  await testSignIn.refresh();
  assert.deepEqual(warnings, [
    "test sign-in password is shorter than 12 characters: test sign-in stays off",
    'the test sign-in secret has no "password" key: test sign-in stays off',
  ]);
  assert.ok(warnings.every((message) => !message.includes(PASSWORD)), "the value is never logged");
});

test("test sign-in: deleting the secret (scheduled for deletion) switches it off at once", async () => {
  const { secrets, testSignIn } = await switchFor(PASSWORD);
  const { accessToken } = testSignIn.signIn({ password: PASSWORD, name: "anna" });
  secrets.deleted = true;
  await testSignIn.refresh();
  assert.equal(testSignIn.on, false);
  await assert.rejects(testSignIn.verify(accessToken), { name: "TestSignInOffError" });
});

test("config: TEST_SIGN_IN_SECRET_ID and SECRETS_REGION; the Secrets Manager client exists only when needed", () => {
  const base = { BEDROCK_REGION: "us-west-2", NOVA_MODEL_ID: "m" };
  const off = loadConfig(base);
  assert.equal(off.testSignInSecretId, null);
  assert.equal(off.secretsRegion, "us-west-2");
  assert.equal(off.timeouts.testSignInRefreshMs, 30000);
  assert.equal(createAwsClients(off).secrets, null);
  assert.equal(createAwsClients(off).ssm, null);

  const on = loadConfig({ ...base, TEST_SIGN_IN_SECRET_ID: ` ${SECRET_ID} `, SECRETS_REGION: "us-east-1" });
  assert.equal(on.testSignInSecretId, SECRET_ID);
  assert.equal(on.secretsRegion, "us-east-1");
  assert.ok(createAwsClients(on).secrets instanceof SecretsManagerClient);
  assert.equal(createAwsClients(on).ssm, null, "the test sign-in no longer needs Parameter Store");
  assert.equal(loadConfig({ ...base, AWS_REGION: "eu-west-1" }).secretsRegion, "eu-west-1");
  assert.equal(loadConfig({ ...base, TEST_SIGN_IN_PARAMETER: "/V2V/POC/testSignIn" }).testSignInSecretId, null, "the old setting is not read");
});

test("test sign-in: the password gets a token that verifies; a wrong password, tampering or expiry does not", async () => {
  let clock = Date.now();
  const { testSignIn } = await switchFor(PASSWORD, { now: () => clock });
  assert.equal(testSignIn.on, true);
  assert.equal(testSignIn.signIn({ password: "wrong-password-123", name: "anna" }), null);

  const session = testSignIn.signIn({ password: PASSWORD, name: "anna" });
  assert.ok(testSignIn.isTestToken(session.accessToken));
  assert.deepEqual(await testSignIn.verify(session.accessToken), { userId: "test:anna", expiresAt: session.expiresAt });
  assert.ok(Math.abs(session.expiresAt - clock - 8 * 60 * 60_000) < 1000, "8 hours");

  const [header, payload, signature] = session.accessToken.split(".");
  const forged = Buffer.from(JSON.stringify({ ...JSON.parse(Buffer.from(payload, "base64url")), sub: "test:admin" })).toString("base64url");
  await assert.rejects(testSignIn.verify(`${header}.${forged}.${signature}`), { name: "TestTokenInvalidError" });

  clock += 8 * 60 * 60_000 + 1000;
  await assert.rejects(testSignIn.verify(session.accessToken), { name: "TestTokenExpiredError" });
});

test("test sign-in: switching off, or a new password, ends every test session; a failed read keeps the state", async () => {
  const { secrets, testSignIn } = await switchFor(PASSWORD);
  const { accessToken } = testSignIn.signIn({ password: PASSWORD, name: "anna" });

  secrets.fail = true;
  await testSignIn.refresh();
  assert.equal((await testSignIn.verify(accessToken)).userId, "test:anna", "a Secrets Manager hiccup changes nothing");
  secrets.fail = false;

  secrets.value = "another-password-456";
  await testSignIn.refresh();
  await assert.rejects(testSignIn.verify(accessToken), { name: "TestTokenInvalidError" });

  secrets.value = "off";
  await testSignIn.refresh();
  await assert.rejects(testSignIn.verify(accessToken), { name: "TestSignInOffError" });
});

test("test sign-in: only test tokens go to the test check; others go to the real verifier", async () => {
  const { testSignIn } = await switchFor(PASSWORD);
  const verifier = withTestSignIn(fakeVerifier, testSignIn);
  assert.equal((await verifier.verify("valid.token.user1")).userId, "user-1");
  const { accessToken } = testSignIn.signIn({ password: PASSWORD, name: "anna" });
  assert.equal((await verifier.verify(accessToken)).userId, "test:anna");
});

const postSignIn = (url, body, contentType = "application/json") =>
  fetch(`${url}/api/test-sign-in`, { method: "POST", headers: { "Content-Type": contentType }, body: JSON.stringify(body) });

test("test sign-in API: on/off status, wrong password 401, token works on the WebSocket, rate limited", async () => {
  const { secrets, testSignIn } = await switchFor(PASSWORD);
  const server = await startTestServer({ verifier: withTestSignIn(fakeVerifier, testSignIn), testSignIn });
  const { httpUrl, wsUrl } = server;

  assert.deepEqual(await (await fetch(`${httpUrl}/api/test-sign-in`)).json(), { enabled: true });
  assert.equal((await postSignIn(httpUrl, { password: "wrong-password-123" })).status, 401);
  assert.equal((await postSignIn(httpUrl, { password: PASSWORD, name: "<script>" })).status, 400);
  assert.equal((await postSignIn(httpUrl, { password: PASSWORD }, "text/plain")).status, 415);

  const res = await postSignIn(httpUrl, { password: PASSWORD, name: "Anna K" });
  assert.equal(res.status, 200);
  const { accessToken } = await res.json();
  const call = await runClient(wsUrl, [auth(accessToken), start("nova"), end()]);
  assert.equal(call.code, CLOSE_CODES.NORMAL);
  assert.deepEqual(call.messages[0], { type: "ready" });

  secrets.value = "off";
  await testSignIn.refresh();
  assert.deepEqual(await (await fetch(`${httpUrl}/api/test-sign-in`)).json(), { enabled: false });
  assert.equal((await postSignIn(httpUrl, { password: PASSWORD })).status, 404);
  assert.equal((await runClient(wsUrl, [auth(accessToken), start("nova")])).code, CLOSE_CODES.UNAUTHORIZED);

  // 10 attempts a minute per client address (5 used above).
  const statuses = [];
  for (let i = 0; i < 6; i++) statuses.push((await postSignIn(httpUrl, { password: "x" })).status);
  assert.equal(statuses.at(-1), 429);
  await server.close();
});

test("test sign-in API: does not exist without a test sign-in secret configured", async () => {
  const server = await startTestServer({ config: testConfig() });
  assert.equal((await fetch(`${server.httpUrl}/api/test-sign-in`)).status, 404);
  assert.equal((await postSignIn(server.httpUrl, { password: PASSWORD })).status, 404);
  await server.close();
});
