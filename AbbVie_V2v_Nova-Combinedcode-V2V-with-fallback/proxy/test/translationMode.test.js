// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
//
// fix 6: the forceBackupTranslation switch (services/translationMode.js) and GET /api/translation-mode.
import { test } from "node:test";
import assert from "node:assert/strict";
import { loadConfig } from "../src/config.js";
import { createProxyServer } from "../src/server.js";
import { createTranslationModeSource } from "../src/services/translationMode.js";
import { VALID_TOKEN, fakeBedrock, fakePolly, fakeTranscribe, fakeTranslate, fakeVerifier, silentLogger, testConfig } from "./helpers.js";

const PARAM = "/Abbvie/NovaSonic/Dev/forceBackupTranslation";

/** SSM fake: returns `state.value`, or throws `state.error`; records every parameter name asked for. */
function fakeSsm(state) {
  return {
    names: [],
    async send(command) {
      this.names.push(command.input.Name);
      if (state.error) throw state.error;
      if (state.value === undefined) throw Object.assign(new Error("not found"), { name: "ParameterNotFound" });
      return { Parameter: { Name: command.input.Name, Value: state.value } };
    },
  };
}

function recordingLogger() {
  const lines = [];
  const log = (level) => (msg, fields) => lines.push({ level, msg, ...fields });
  return { lines, debug: log("debug"), info: log("info"), warn: log("warn"), error: log("error") };
}

async function startServer(translationMode) {
  const proxy = createProxyServer({
    config: testConfig(),
    verifier: fakeVerifier,
    logger: silentLogger,
    clients: { bedrock: fakeBedrock(), transcribe: fakeTranscribe(), translate: fakeTranslate(), polly: fakePolly() },
    translationMode,
  });
  const { port } = await proxy.listen(0, "127.0.0.1");
  return { url: `http://127.0.0.1:${port}`, close: () => proxy.shutdown() };
}

const getMode = (url, { token = VALID_TOKEN, method = "GET" } = {}) =>
  fetch(`${url}/api/translation-mode`, { method, headers: token ? { Authorization: `Bearer ${token}` } : {} });

test("switch: only the value \"true\" (any case, spaces ignored) turns it on", async () => {
  for (const [value, expected] of [
    ["true", true],
    [" TRUE ", true],
    ["True", true],
    ["false", false],
    ["yes", false],
    ["1", false],
    ["", false],
  ]) {
    const source = createTranslationModeSource({ ssm: fakeSsm({ value }), parameterName: PARAM, logger: silentLogger });
    assert.equal(await source.refresh(), expected, `value ${JSON.stringify(value)}`);
    assert.deepEqual(source.current(), { forceBackup: expected });
  }
});

test("switch: a missing parameter is off, and is logged once", async () => {
  const logger = recordingLogger();
  const state = { value: undefined };
  const source = createTranslationModeSource({ ssm: fakeSsm(state), parameterName: PARAM, logger });
  assert.equal(await source.refresh(), false);
  assert.equal(await source.refresh(), false);
  assert.equal(logger.lines.filter((l) => l.msg.includes("not found")).length, 1);
});

test("switch: turns on and off as the parameter changes; each change is logged", async () => {
  const logger = recordingLogger();
  const state = { value: "false" };
  const ssm = fakeSsm(state);
  const source = createTranslationModeSource({ ssm, parameterName: PARAM, logger });
  assert.equal(await source.refresh(), false);
  state.value = "true";
  assert.equal(await source.refresh(), true);
  state.value = undefined; // deleted
  assert.equal(await source.refresh(), false);
  assert.deepEqual(ssm.names, [PARAM, PARAM, PARAM]);
  const changes = logger.lines.filter((l) => l.msg === "translation mode changed");
  assert.deepEqual(changes.map((c) => c.forceBackup), [true, false]);
});

test("switch: a failed read keeps the last value, warns once, and recovers", async () => {
  const logger = recordingLogger();
  const state = { value: "true" };
  const source = createTranslationModeSource({ ssm: fakeSsm(state), parameterName: PARAM, logger });
  assert.equal(await source.refresh(), true);
  state.error = Object.assign(new Error("denied"), { name: "AccessDeniedException" });
  assert.equal(await source.refresh(), true);
  assert.equal(await source.refresh(), true);
  assert.equal(logger.lines.filter((l) => l.level === "warn").length, 1);
  state.error = null;
  state.value = "false";
  assert.equal(await source.refresh(), false);
  assert.ok(logger.lines.some((l) => l.msg === "translation mode parameter readable again"));
});

test("switch: without a parameter name or SSM client it is off and never calls AWS", async () => {
  const ssm = fakeSsm({ value: "true" });
  const noName = createTranslationModeSource({ ssm, parameterName: null, logger: silentLogger });
  assert.equal(noName.enabled, false);
  assert.equal(await noName.start(), false);
  assert.equal(await noName.refresh(), false);
  const noClient = createTranslationModeSource({ ssm: null, parameterName: PARAM, logger: silentLogger });
  assert.equal(await noClient.refresh(), false);
  assert.deepEqual(ssm.names, []);
});

test("switch: start() reads at once and then every refreshMs; stop() ends it", async () => {
  const state = { value: "false" };
  const ssm = fakeSsm(state);
  const source = createTranslationModeSource({ ssm, parameterName: PARAM, refreshMs: 30, logger: silentLogger });
  assert.equal(await source.start(), false);
  state.value = "true";
  await new Promise((r) => setTimeout(r, 100));
  assert.equal(source.current().forceBackup, true);
  source.stop();
  const reads = ssm.names.length;
  await new Promise((r) => setTimeout(r, 100));
  assert.equal(ssm.names.length, reads);
});

test("config: FORCE_BACKUP_PARAMETER and SSM_REGION, with their defaults", () => {
  const base = { COGNITO_USER_POOL_ID: "p", COGNITO_CLIENT_ID: "c", BEDROCK_REGION: "us-west-2", NOVA_MODEL_ID: "m" };
  const off = loadConfig(base);
  assert.equal(off.forceBackupParameter, null);
  assert.equal(off.ssmRegion, "us-west-2");
  assert.equal(off.timeouts.translationModeRefreshMs, 30000);
  assert.equal(off.limits.fallbackRequestsPerMinute, 60);
  const on = loadConfig({ ...base, FORCE_BACKUP_PARAMETER: ` ${PARAM} `, SSM_REGION: "us-east-1", FALLBACK_REQUESTS_PER_MINUTE: "150" });
  assert.equal(on.forceBackupParameter, PARAM);
  assert.equal(on.ssmRegion, "us-east-1");
  assert.equal(on.limits.fallbackRequestsPerMinute, 150);
  assert.equal(loadConfig({ ...base, AWS_REGION: "eu-west-1" }).ssmRegion, "eu-west-1");
});

test("GET /api/translation-mode: needs a valid token, returns the switch, is never cached", async () => {
  const state = { value: "true" };
  const source = createTranslationModeSource({ ssm: fakeSsm(state), parameterName: PARAM, logger: silentLogger });
  await source.refresh();
  const server = await startServer(source);
  try {
    assert.equal((await getMode(server.url, { token: null })).status, 401);
    assert.equal((await getMode(server.url, { token: "forged.token" })).status, 401);
    assert.equal((await getMode(server.url, { method: "POST" })).status, 405);
    const on = await getMode(server.url);
    assert.equal(on.status, 200);
    assert.equal(on.headers.get("cache-control"), "no-store");
    assert.deepEqual(await on.json(), { forceBackup: true });
    state.value = "false";
    await source.refresh();
    assert.deepEqual(await (await getMode(server.url)).json(), { forceBackup: false });
  } finally {
    await server.close();
  }
});

test("GET /api/translation-mode: off when the server has no switch configured", async () => {
  const server = await startServer(undefined);
  try {
    const res = await getMode(server.url);
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { forceBackup: false });
  } finally {
    await server.close();
  }
});
