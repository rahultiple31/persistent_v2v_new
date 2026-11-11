// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import { test } from "node:test";
import assert from "node:assert/strict";
import { Readable } from "node:stream";
import { VALID_TOKEN, startTestServer, testConfig } from "./helpers.js";

const KEY = "2026/11/03/0b6c4c63-5b2e-4f1a-9d1e-3f2a7c9e8d10.wav";
const WAV = Buffer.from("RIFF....WAVEfmt fake recording bytes");

/** S3 fake: answers GetObject from `objects` (key -> bytes), or throws `failWith`. */
function fakeS3({ objects = { [KEY]: WAV }, failWith, body } = {}) {
  return {
    commands: [],
    async send(command, options) {
      this.commands.push({ input: command.input, options });
      if (failWith) throw failWith;
      if (body) return { Body: body, ContentLength: undefined };
      const bytes = objects[command.input.Key];
      if (!bytes) throw Object.assign(new Error("The specified key does not exist."), { name: "NoSuchKey", $metadata: { httpStatusCode: 404 } });
      return { Body: Readable.from([bytes]), ContentLength: bytes.length, ContentType: "text/html" };
    },
  };
}

const voicemailConfig = (extra = {}) => testConfig({ VOICEMAIL_BUCKET: "btsgsd-v2v-us-voicemail", ...extra });
const getRecording = (url, key, { token = VALID_TOKEN, method = "GET", signal } = {}) =>
  fetch(`${url}/api/voicemail${key == null ? "" : `?key=${encodeURIComponent(key)}`}`, {
    method,
    headers: token ? { Authorization: `Bearer ${token}` } : {},
    signal,
  });

test("Voicemail: streams the recording from the configured bucket as WAV, never cached", async () => {
  const s3 = fakeS3();
  const server = await startTestServer({ config: voicemailConfig(), clients: { s3 } });
  const res = await getRecording(server.httpUrl, KEY);
  assert.equal(res.status, 200);
  // S3's stored type is not trusted.
  assert.equal(res.headers.get("content-type"), "audio/wav");
  assert.equal(res.headers.get("cache-control"), "no-store");
  assert.equal(res.headers.get("x-content-type-options"), "nosniff");
  assert.equal(res.headers.get("cross-origin-resource-policy"), "same-origin");
  assert.equal(Number(res.headers.get("content-length")), WAV.length);
  assert.deepEqual(Buffer.from(await res.arrayBuffer()), WAV);
  assert.deepEqual(s3.commands[0].input, { Bucket: "btsgsd-v2v-us-voicemail", Key: KEY });
  await server.close();
});

test("Voicemail: only VMX3 recording names are read; anything else is refused before S3", async () => {
  const s3 = fakeS3();
  const server = await startTestServer({ config: voicemailConfig(), clients: { s3 } });
  for (const key of [
    null,
    "",
    "../secret.wav",
    "2026/11/03/../../other/0b6c4c63-5b2e-4f1a-9d1e-3f2a7c9e8d10.wav",
    "2026/11/03/0b6c4c63-5b2e-4f1a-9d1e-3f2a7c9e8d10.mp3",
    "2026/13/03/0b6c4c63-5b2e-4f1a-9d1e-3f2a7c9e8d10.wav",
    "other-prefix/2026/11/03/0b6c4c63-5b2e-4f1a-9d1e-3f2a7c9e8d10.wav",
    "2026/11/03/not-a-contact-id.wav",
    `${KEY}\n`,
  ]) {
    const res = await getRecording(server.httpUrl, key);
    assert.equal(res.status, 400, `key ${JSON.stringify(key)}`);
    assert.deepEqual(await res.json(), { error: "invalidRecordingKey" });
  }
  assert.equal(s3.commands.length, 0);
  await server.close();
});

test("Voicemail: needs a signed-in user and GET", async () => {
  const s3 = fakeS3();
  const server = await startTestServer({ config: voicemailConfig(), clients: { s3 } });
  assert.equal((await getRecording(server.httpUrl, KEY, { token: null })).status, 401);
  assert.equal((await getRecording(server.httpUrl, KEY, { token: "forged.token" })).status, 401);
  const post = await getRecording(server.httpUrl, KEY, { method: "POST" });
  assert.equal(post.status, 405);
  assert.equal(post.headers.get("allow"), "GET");
  assert.equal(s3.commands.length, 0);
  await server.close();
});

test("Voicemail: without a bucket configured, playback is off", async () => {
  const server = await startTestServer();
  const res = await getRecording(server.httpUrl, KEY);
  assert.equal(res.status, 404);
  assert.deepEqual(await res.json(), { error: "voicemailOff" });
  await server.close();
});

test("Voicemail: a missing file is 404; S3 refusing (permission, key policy) is 502", async () => {
  let server = await startTestServer({ config: voicemailConfig(), clients: { s3: fakeS3({ objects: {} }) } });
  let res = await getRecording(server.httpUrl, KEY);
  assert.equal(res.status, 404);
  assert.deepEqual(await res.json(), { error: "recordingNotFound" });
  await server.close();

  const denied = Object.assign(new Error("Access Denied"), { name: "AccessDenied", $metadata: { httpStatusCode: 403 } });
  server = await startTestServer({ config: voicemailConfig(), clients: { s3: fakeS3({ failWith: denied }) } });
  res = await getRecording(server.httpUrl, KEY);
  assert.equal(res.status, 502);
  assert.deepEqual(await res.json(), { error: "recordingUnavailable" });
  await server.close();
});

test("Voicemail: requests per user are rate limited", async () => {
  const server = await startTestServer({ config: voicemailConfig({ VOICEMAIL_REQUESTS_PER_MINUTE: "2" }), clients: { s3: fakeS3() } });
  assert.equal((await getRecording(server.httpUrl, KEY)).status, 200);
  assert.equal((await getRecording(server.httpUrl, KEY)).status, 200);
  const limited = await getRecording(server.httpUrl, KEY);
  assert.equal(limited.status, 429);
  assert.equal(limited.headers.get("retry-after"), "10");
  await server.close();
});

test("Voicemail: when the browser goes away mid-download, the read from S3 is stopped", async () => {
  // A recording that never finishes arriving.
  let destroyed;
  const destroyedPromise = new Promise((resolve) => {
    destroyed = resolve;
  });
  const body = new Readable({
    read() {},
    destroy(err, callback) {
      destroyed();
      callback(err);
    },
  });
  body.push(Buffer.from("RIFF"));
  const server = await startTestServer({ config: voicemailConfig(), clients: { s3: fakeS3({ body }) } });
  const abort = new AbortController();
  const res = await getRecording(server.httpUrl, KEY, { signal: abort.signal });
  assert.equal(res.status, 200);
  const reader = res.body.getReader();
  await reader.read();
  abort.abort();
  await destroyedPromise;
  await server.close();
});

test("Config: VOICEMAIL_BUCKET must be a bucket name; its Region defaults to the task's", () => {
  assert.equal(testConfig().voicemail, null);
  assert.deepEqual(voicemailConfig().voicemail, { bucket: "btsgsd-v2v-us-voicemail", region: "us-east-1" });
  assert.deepEqual(voicemailConfig({ VOICEMAIL_REGION: "us-west-2" }).voicemail.region, "us-west-2");
  assert.throws(() => voicemailConfig({ VOICEMAIL_BUCKET: "BTSGSD-V2V-US-voicemail" }), /VOICEMAIL_BUCKET is not a valid bucket name/);
  assert.throws(() => voicemailConfig({ VOICEMAIL_BUCKET: "s3://bucket" }), /VOICEMAIL_BUCKET is not a valid bucket name/);
});
