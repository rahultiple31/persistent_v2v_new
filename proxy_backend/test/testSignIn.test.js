import { test } from "node:test";
import assert from "node:assert/strict";
import { CLOSE_CODES } from "../src/server.js";
import { createTestSignIn, withTestSignIn } from "../src/services/testSignIn.js";
import { auth, end, fakeVerifier, runClient, silentLogger, start, startTestServer, testConfig } from "./helpers.js";

const PASSWORD = "correct-horse-battery";

/** A Parameter Store fake holding one value; null = no parameter. */
function fakeSsm(initial) {
  return {
    value: initial,
    fail: false,
    async send(command) {
      assert.equal(command.input.WithDecryption, true);
      if (this.fail) throw Object.assign(new Error("throttled"), { name: "ThrottlingException" });
      if (this.value == null) throw Object.assign(new Error("not found"), { name: "ParameterNotFound" });
      return { Parameter: { Value: this.value } };
    },
  };
}

async function switchFor(value, opts = {}) {
  const ssm = fakeSsm(value);
  const testSignIn = createTestSignIn({ ssm, parameterName: "/V2V/POC/testSignIn", logger: silentLogger, ...opts });
  await testSignIn.refresh();
  return { ssm, testSignIn };
}

test("test sign-in: off without a parameter, with 'off', and with a password under 12 characters", async () => {
  for (const value of [null, "off", " OFF ", "short-pw"]) {
    const { testSignIn } = await switchFor(value);
    assert.equal(testSignIn.on, false, String(value));
    assert.equal(testSignIn.signIn({ password: value ?? "", name: "a" }), null);
  }
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
  const { ssm, testSignIn } = await switchFor(PASSWORD);
  const { accessToken } = testSignIn.signIn({ password: PASSWORD, name: "anna" });

  ssm.fail = true;
  await testSignIn.refresh();
  assert.equal((await testSignIn.verify(accessToken)).userId, "test:anna", "a Parameter Store hiccup changes nothing");
  ssm.fail = false;

  ssm.value = "another-password-456";
  await testSignIn.refresh();
  await assert.rejects(testSignIn.verify(accessToken), { name: "TestTokenInvalidError" });

  ssm.value = "off";
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
  const { ssm, testSignIn } = await switchFor(PASSWORD);
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

  ssm.value = "off";
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

test("test sign-in API: does not exist without the switch (testSignIn: false)", async () => {
  const server = await startTestServer({ config: testConfig() });
  assert.equal((await fetch(`${server.httpUrl}/api/test-sign-in`)).status, 404);
  assert.equal((await postSignIn(server.httpUrl, { password: PASSWORD })).status, 404);
  await server.close();
});
