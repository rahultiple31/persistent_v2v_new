// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import { test } from "node:test";
import assert from "node:assert/strict";
import { WebSocket } from "ws";
import { CLOSE_CODES } from "../src/server.js";
import {
  OTHER_USER_TOKEN,
  VALID_TOKEN,
  auth,
  end,
  fakeBedrock,
  fakePolly,
  fakeTranslate,
  novaEvent,
  runClient,
  start,
  startTestServer,
  testConfig,
} from "./helpers.js";

const postFallback = (url, body, { token = VALID_TOKEN, contentType = "application/json" } = {}) =>
  fetch(`${url}/api/fallback`, {
    method: "POST",
    headers: { "Content-Type": contentType, ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });

test("health check reports ok, and draining during shutdown", async () => {
  const server = await startTestServer();
  const res = await fetch(`${server.httpUrl}/healthz`);
  assert.equal(res.status, 200);
  assert.equal(res.headers.get("cache-control"), "no-store");
  assert.deepEqual(await res.json(), { status: "ok" });
  assert.equal((await fetch(`${server.httpUrl}/nope`)).status, 404);
  await server.close();
});

test("rejects a WebSocket upgrade from a disallowed origin", async () => {
  const server = await startTestServer();
  await assert.rejects(runClient(server.wsUrl, [], { origin: "https://evil.example.com" }), /Unexpected server response: 403/);
  await server.close();
});

test("closes with 4401 when the first frame is not a valid auth message", async () => {
  const server = await startTestServer();
  assert.equal((await runClient(server.wsUrl, [auth("forged.token")])).code, CLOSE_CODES.UNAUTHORIZED);
  assert.equal((await runClient(server.wsUrl, [start("nova")])).code, CLOSE_CODES.UNAUTHORIZED);
  await server.close();
});

test("closes with 4401 when no auth frame arrives in time", async () => {
  const server = await startTestServer({ config: testConfig({ AUTH_TIMEOUT_MS: "50" }) });
  assert.equal((await runClient(server.wsUrl, [])).code, CLOSE_CODES.UNAUTHORIZED);
  await server.close();
});

test("Nova: pipelined auth + start + events are relayed in order, then the stream ends cleanly", async () => {
  const bedrock = fakeBedrock();
  const server = await startTestServer({ clients: { bedrock } });
  const events = [novaEvent("sessionStart", { n: 1 }), novaEvent("audioInput", { content: "AAAA" }), novaEvent("sessionEnd")];
  const { messages, code } = await runClient(server.wsUrl, [auth(), start("nova"), ...events, end()]);

  assert.equal(code, CLOSE_CODES.NORMAL);
  assert.deepEqual(messages[0], { type: "ready" });
  assert.deepEqual(
    messages.slice(1, -1).map((m) => m.binary.toString()),
    events.map((e) => e.toString()),
  );
  assert.deepEqual(messages.at(-1), { type: "end" });
  // The model comes from server configuration, not the client.
  assert.equal(bedrock.commands[0].input.modelId, "amazon.nova-2-sonic-v1:0");
  await server.close();
});

test("Nova: a disallowed event is rejected with 4400", async () => {
  const server = await startTestServer();
  const { messages, code } = await runClient(server.wsUrl, [auth(), start("nova"), novaEvent("toolResult")]);
  assert.equal(code, CLOSE_CODES.BAD_REQUEST);
  assert.equal(messages.find((m) => m.type === "error").code, "invalidEvent");
  await server.close();
});

test("Nova: an upstream failure is reported without leaking AWS details", async () => {
  const denied = Object.assign(new Error("User: arn:aws:sts::123456789012:assumed-role/TaskRole is not authorized"), {
    name: "AccessDeniedException",
  });
  const server = await startTestServer({ clients: { bedrock: fakeBedrock({ failWith: denied }) } });
  const { messages, code } = await runClient(server.wsUrl, [auth(), start("nova")]);
  assert.equal(code, CLOSE_CODES.INTERNAL_ERROR);
  assert.deepEqual(messages, [{ type: "error", code: "accessDeniedException", message: "The upstream AWS request failed" }]);
  await server.close();
});

test("Transcribe: relays final transcripts only, and validates start parameters", async () => {
  const server = await startTestServer();
  const audio = [Buffer.alloc(3200), Buffer.alloc(1600)];
  const { messages, code } = await runClient(server.wsUrl, [
    auth(),
    start("transcribe", { languageCode: "es-US", sampleRate: 16000 }),
    ...audio,
    end(),
  ]);
  assert.equal(code, CLOSE_CODES.NORMAL);
  assert.deepEqual(messages, [
    { type: "ready" },
    { type: "transcript", text: "final 1 3200" },
    { type: "transcript", text: "final 2 1600" },
    { type: "end" },
  ]);

  const bad = await runClient(server.wsUrl, [auth(), start("transcribe", { languageCode: "es", sampleRate: 16000 })]);
  assert.equal(bad.code, CLOSE_CODES.BAD_REQUEST);
  await server.close();
});

test("Transcribe: 'ready' only arrives once audio flows, so clients must send audio before waiting for it", async () => {
  const server = await startTestServer();
  const ws = new WebSocket(server.wsUrl, { origin: "https://app.example.com" });
  const messages = [];
  ws.on("message", (data) => messages.push(JSON.parse(data.toString())));
  await new Promise((resolve) => ws.on("open", resolve));
  ws.send(auth());
  ws.send(start("transcribe", { languageCode: "en-US", sampleRate: 16000 }));

  await new Promise((resolve) => setTimeout(resolve, 200));
  assert.deepEqual(messages, [], "no ready before any audio");

  ws.send(Buffer.alloc(3200), { binary: true });
  await new Promise((resolve) => setTimeout(resolve, 200));
  assert.deepEqual(messages.slice(0, 2), [{ type: "ready" }, { type: "transcript", text: "final 1 3200" }]);
  ws.close();
  await server.close();
});

test("enforces the per-user connection limit", async () => {
  const server = await startTestServer({ config: testConfig({ MAX_CONNECTIONS_PER_USER: "1" }) });
  const first = new WebSocket(server.wsUrl, { origin: "https://app.example.com" });
  await new Promise((resolve) => first.on("open", resolve));
  first.send(auth());
  await new Promise((resolve) => setTimeout(resolve, 50));

  assert.equal((await runClient(server.wsUrl, [auth()])).code, CLOSE_CODES.TOO_MANY_CONNECTIONS);
  // A different user is unaffected.
  const other = await runClient(server.wsUrl, [auth(OTHER_USER_TOKEN), start("nova"), end()]);
  assert.equal(other.code, CLOSE_CODES.NORMAL);
  first.close();
  await server.close();
});

test("shutdown moves idle pooled sockets off the task with 1012", async () => {
  const server = await startTestServer();
  const pooled = runClient(server.wsUrl, [auth()]);
  await new Promise((resolve) => setTimeout(resolve, 50));
  await server.close();
  assert.equal((await pooled).code, CLOSE_CODES.SERVICE_RESTART);
});

test("fallback: requires a valid bearer token", async () => {
  const server = await startTestServer();
  const body = { text: "hello", sourceLanguageCode: "en", targetLanguageCode: "es" };
  assert.equal((await postFallback(server.httpUrl, body, { token: null })).status, 401);
  assert.equal((await postFallback(server.httpUrl, body, { token: "forged.token" })).status, 401);
  await server.close();
});

test("fallback: translates and synthesises, or returns text only when Polly fails", async () => {
  const body = { text: "hello", sourceLanguageCode: "en", targetLanguageCode: "es", voiceId: "Lupe", engine: "neural" };
  let server = await startTestServer();
  let res = await postFallback(server.httpUrl, body);
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { translatedText: "[es] hello", audio: Buffer.from([1, 2, 3]).toString("base64"), audioError: false });
  await server.close();

  server = await startTestServer({ clients: { polly: fakePolly({ fail: true }) } });
  res = await postFallback(server.httpUrl, body);
  assert.deepEqual(await res.json(), { translatedText: "[es] hello", audio: null, audioError: true });
  await server.close();
});

test("fallback: 502 when Translate fails; 400/413/415 for bad requests; 429 when rate limited", async () => {
  const body = { text: "hello", sourceLanguageCode: "en", targetLanguageCode: "es" };
  let server = await startTestServer({ clients: { translate: fakeTranslate({ fail: true }) } });
  assert.equal((await postFallback(server.httpUrl, body)).status, 502);
  await server.close();

  server = await startTestServer({ config: testConfig({ FALLBACK_REQUESTS_PER_MINUTE: "3" }) });
  assert.equal((await postFallback(server.httpUrl, { ...body, sourceLanguageCode: "english" })).status, 400);
  assert.equal((await postFallback(server.httpUrl, { ...body, text: "x".repeat(20_000) })).status, 413);
  assert.equal((await postFallback(server.httpUrl, "hello", { contentType: "text/plain" })).status, 415);
  assert.equal((await postFallback(server.httpUrl, body)).status, 429);
  await server.close();
});
