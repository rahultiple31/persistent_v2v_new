// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import { WebSocket } from "ws";
import { loadConfig } from "../src/config.js";
import { createProxyServer } from "../src/server.js";

export const ALLOWED_ORIGIN = "https://app.example.com";
export const VALID_TOKEN = "valid.token.user1";
export const OTHER_USER_TOKEN = "valid.token.user2";

export function testConfig(overrides = {}) {
  return loadConfig({
    COGNITO_USER_POOL_ID: "us-east-1_test",
    COGNITO_CLIENT_ID: "client",
    BEDROCK_REGION: "us-east-1",
    NOVA_MODEL_ID: "amazon.nova-2-sonic-v1:0",
    ALLOWED_ORIGINS: `${ALLOWED_ORIGIN}/`,
    HEARTBEAT_INTERVAL_MS: "60000",
    DRAIN_TIMEOUT_MS: "200",
    ...overrides,
  });
}

export const fakeVerifier = {
  async verify(token) {
    if (token === VALID_TOKEN) return { userId: "user-1", expiresAt: Date.now() + 3_600_000 };
    if (token === OTHER_USER_TOKEN) return { userId: "user-2", expiresAt: Date.now() + 3_600_000 };
    const err = new Error("Invalid token");
    err.name = "JwtInvalidSignatureError";
    throw err;
  },
};

/** Bedrock fake: echoes every input event back as an output event, ends when the input ends. */
export function fakeBedrock({ failWith } = {}) {
  return {
    commands: [],
    async send(command) {
      this.commands.push(command);
      if (failWith) throw failWith;
      const input = command.input.body;
      return {
        body: (async function* () {
          for await (const item of input) yield { chunk: { bytes: item.chunk.bytes } };
        })(),
      };
    },
  };
}

/**
 * Transcribe fake: for every audio chunk emits a partial and a final result. Like the real service, it
 * accepts the stream (send() resolves) only once the first audio chunk has arrived.
 */
export function fakeTranscribe() {
  return {
    commands: [],
    async send(command) {
      this.commands.push(command);
      const audio = command.input.AudioStream[Symbol.asyncIterator]();
      const first = await audio.next();
      return {
        TranscriptResultStream: (async function* () {
          let n = 0;
          for (let event = first; !event.done; event = await audio.next()) {
            n++;
            const bytes = event.value.AudioEvent.AudioChunk.length;
            yield { TranscriptEvent: { Transcript: { Results: [{ IsPartial: true, Alternatives: [{ Transcript: "partial" }] }] } } };
            yield { TranscriptEvent: { Transcript: { Results: [{ IsPartial: false, Alternatives: [{ Transcript: `final ${n} ${bytes}` }] }] } } };
          }
        })(),
      };
    },
  };
}

export function fakeTranslate({ fail = false } = {}) {
  return {
    async send(command) {
      if (fail) throw Object.assign(new Error("boom"), { name: "InternalServerException" });
      return { TranslatedText: `[${command.input.TargetLanguageCode}] ${command.input.Text}` };
    },
  };
}

export function fakePolly({ fail = false } = {}) {
  return {
    async send() {
      if (fail) throw Object.assign(new Error("boom"), { name: "ServiceFailureException" });
      return { AudioStream: { transformToByteArray: async () => new Uint8Array([1, 2, 3]) } };
    },
  };
}

export const silentLogger = { debug() {}, info() {}, warn() {}, error() {} };

export async function startTestServer({ config = testConfig(), clients = {}, verifier = fakeVerifier } = {}) {
  const proxy = createProxyServer({
    config,
    verifier,
    logger: silentLogger,
    clients: {
      bedrock: fakeBedrock(),
      transcribe: fakeTranscribe(),
      translate: fakeTranslate(),
      polly: fakePolly(),
      ...clients,
    },
  });
  const { port } = await proxy.listen(0, "127.0.0.1");
  return {
    proxy,
    httpUrl: `http://127.0.0.1:${port}`,
    wsUrl: `ws://127.0.0.1:${port}/ws`,
    async close() {
      await proxy.shutdown();
    },
  };
}

/**
 * Opens a WebSocket, sends `frames` back to back as soon as it opens (strings as text, Buffers as
 * binary), and collects everything until the server closes.
 */
export function runClient(url, frames, { origin = ALLOWED_ORIGIN, onMessage } = {}) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url, { origin });
    const messages = [];
    ws.on("open", () => {
      for (const frame of frames) ws.send(frame, { binary: Buffer.isBuffer(frame) });
    });
    ws.on("message", (data, isBinary) => {
      const message = isBinary ? { binary: Buffer.from(data) } : JSON.parse(data.toString());
      messages.push(message);
      onMessage?.(message, ws);
    });
    ws.on("close", (code, reason) => resolve({ messages, code, reason: reason.toString() }));
    ws.on("error", reject);
  });
}

export const auth = (token = VALID_TOKEN) => JSON.stringify({ type: "auth", token });
export const start = (service, extra = {}) => JSON.stringify({ type: "start", service, ...extra });
export const end = () => JSON.stringify({ type: "end" });
export const novaEvent = (type, body = {}) => Buffer.from(JSON.stringify({ event: { [type]: body } }));
