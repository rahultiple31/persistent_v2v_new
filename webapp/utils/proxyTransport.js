// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
//
// Browser side of the server-side proxy (protocol: proxy/src/server.js). With the proxy enabled the
// browser never obtains AWS credentials: Nova Sonic and Transcribe stream over a same-origin WebSocket
// (/ws), and the Translate + Polly fallback is a same-origin POST (/api/fallback). Both authenticate
// with the agent's Cognito access token, which is sent in the first WebSocket frame, never in a URL.
//
// Latency: the proxy runs next to Bedrock and is reached through CloudFront, so it replaces the
// browser -> AWS hop rather than adding one. The pool below keeps sockets connected and authenticated
// ahead of time, so Start does not wait for a TCP + TLS + WebSocket handshake either.
import { LOGGER_PREFIX } from "../constants";
import { decodeToken, getValidTokens } from "./authUtility";
import { base64ToArrayBuffer } from "./commonUtility";

const WS_PATH = "/ws";
const FALLBACK_PATH = "/api/fallback";
const TRANSLATION_MODE_PATH = "/api/translation-mode";

// Start opens three streams at once: the customer and agent Nova Sonic sessions and the agent's
// Transcribe stream.
const POOL_SIZE = 3;
// The proxy closes authenticated-but-unused sockets after 10 minutes; recycle well before that.
const POOL_SOCKET_MAX_AGE_MS = 4 * 60_000;
const POOL_MAINTENANCE_INTERVAL_MS = 30_000;
const POOL_RETRY_INITIAL_MS = 1_000;
const POOL_RETRY_MAX_MS = 30_000;
// A socket that stayed open this long counts as healthy and resets the reconnect backoff.
const POOL_HEALTHY_SOCKET_MS = 60_000;
const TOKEN_EXPIRY_MARGIN_MS = 60_000;
const CONNECT_TIMEOUT_MS = 10_000;
const READY_TIMEOUT_MS = 15_000;

// Stream exceptions the Nova Sonic response parser already handles as terminal stream events.
const NOVA_STREAM_EXCEPTIONS = new Set([
  "modelStreamErrorException",
  "internalServerException",
  "validationException",
  "throttlingException",
  "serviceUnavailableException",
]);

function proxyWebSocketUrl() {
  const url = new URL(WS_PATH, window.location.origin);
  url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
  return url.href;
}

async function getAccessToken() {
  const tokens = await getValidTokens();
  if (!tokens?.accessToken) throw new Error("Not signed in: no access token for the translation proxy");
  return tokens.accessToken;
}

function proxyError({ code, message }) {
  const error = new Error(message || code);
  error.name = code || "ProxyError";
  return error;
}

function closedError(closeInfo) {
  const detail = closeInfo ? ` (code ${closeInfo.code}${closeInfo.reason ? `, ${closeInfo.reason}` : ""})` : "";
  return new Error(`Translation proxy connection closed unexpectedly${detail}`);
}

/** FIFO of socket messages, consumed with for-await. */
class MessageQueue {
  #items = [];
  #waiters = [];
  #closed = false;

  push(item) {
    if (this.#closed) return;
    const waiter = this.#waiters.shift();
    if (waiter) waiter({ value: item, done: false });
    else this.#items.push(item);
  }

  close() {
    this.#closed = true;
    for (const waiter of this.#waiters.splice(0)) waiter({ value: undefined, done: true });
  }

  [Symbol.asyncIterator]() {
    return {
      next: () => {
        if (this.#items.length) return Promise.resolve({ value: this.#items.shift(), done: false });
        if (this.#closed) return Promise.resolve({ value: undefined, done: true });
        return new Promise((resolve) => this.#waiters.push(resolve));
      },
    };
  }
}

/** An open WebSocket that has already sent its auth frame. */
class ProxySocket {
  constructor(ws, tokenExpiresAt) {
    this.ws = ws;
    this.createdAt = Date.now();
    this.tokenExpiresAt = tokenExpiresAt;
  }

  static async open() {
    const token = await getAccessToken();
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(proxyWebSocketUrl());
      ws.binaryType = "arraybuffer";
      const timer = setTimeout(() => {
        ws.close();
        reject(new Error("Timed out connecting to the translation proxy"));
      }, CONNECT_TIMEOUT_MS);
      ws.onopen = () => {
        clearTimeout(timer);
        // Sent without waiting for an acknowledgement: the proxy verifies it while the next frames arrive.
        ws.send(JSON.stringify({ type: "auth", token }));
        resolve(new ProxySocket(ws, (decodeToken(token)?.exp ?? 0) * 1000));
      };
      ws.onclose = (event) => {
        clearTimeout(timer);
        reject(new Error(`Could not connect to the translation proxy (close code ${event.code})`));
      };
    });
  }

  isFresh() {
    const now = Date.now();
    return (
      this.ws.readyState === WebSocket.OPEN &&
      now - this.createdAt < POOL_SOCKET_MAX_AGE_MS &&
      this.tokenExpiresAt - now > TOKEN_EXPIRY_MARGIN_MS
    );
  }

  close() {
    if (this.ws.readyState <= WebSocket.OPEN) this.ws.close(1000);
  }
}

/** Keeps POOL_SIZE authenticated sockets ready so a stream start skips the connection handshake. */
class ProxySocketPool {
  #idle = [];
  #started = false;
  #filling = false;
  #retryTimer = null;
  #retryDelay = POOL_RETRY_INITIAL_MS;

  start() {
    if (this.#started) return;
    this.#started = true;
    setInterval(() => this.#maintain(), POOL_MAINTENANCE_INTERVAL_MS);
    this.#fill();
  }

  async acquire() {
    while (this.#idle.length) {
      const socket = this.#idle.shift();
      if (socket.isFresh()) {
        this.#fill();
        return socket;
      }
      socket.close();
    }
    this.#fill();
    return ProxySocket.open();
  }

  #maintain() {
    this.#idle = this.#idle.filter((socket) => {
      if (socket.isFresh()) return true;
      socket.close();
      return false;
    });
    this.#fill();
  }

  #scheduleFill() {
    if (this.#retryTimer) return;
    this.#retryTimer = setTimeout(() => {
      this.#retryTimer = null;
      this.#fill();
    }, this.#retryDelay);
    this.#retryDelay = Math.min(this.#retryDelay * 2, POOL_RETRY_MAX_MS);
  }

  async #fill() {
    if (!this.#started || this.#filling || this.#retryTimer) return;
    this.#filling = true;
    try {
      while (this.#idle.length < POOL_SIZE) {
        const socket = await ProxySocket.open();
        // The proxy closes idle sockets on deployments (1012) and after its idle timeout: drop and refill.
        socket.ws.onclose = () => {
          this.#idle = this.#idle.filter((s) => s !== socket);
          if (Date.now() - socket.createdAt >= POOL_HEALTHY_SOCKET_MS) this.#retryDelay = POOL_RETRY_INITIAL_MS;
          this.#scheduleFill();
        };
        this.#idle.push(socket);
      }
    } catch (err) {
      console.warn(`${LOGGER_PREFIX} - proxy pool: could not open a warm connection, retrying in ${this.#retryDelay}ms`, err.message);
      this.#scheduleFill();
    } finally {
      this.#filling = false;
    }
  }
}

const pool = new ProxySocketPool();

/** One upstream stream (Nova Sonic or Transcribe) on one socket. */
class ProxyStream {
  #ws;
  #inbox = new MessageQueue();
  #ended = false;
  closeInfo = null;
  ready;
  closed;

  constructor(socket, startMessage) {
    this.#ws = socket.ws;
    if (this.#ws.readyState !== WebSocket.OPEN) throw closedError(null);

    let settled = false;
    let resolveReady;
    let rejectReady;
    this.ready = new Promise((resolve, reject) => {
      resolveReady = resolve;
      rejectReady = reject;
    });
    const timer = setTimeout(() => settleReady(new Error("Timed out waiting for the translation proxy stream")), READY_TIMEOUT_MS);
    const settleReady = (error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (error) {
        rejectReady(error);
        this.close();
      } else {
        resolveReady();
      }
    };

    this.closed = new Promise((resolve) => {
      this.#ws.onclose = (event) => {
        this.closeInfo = { code: event.code, reason: event.reason };
        settleReady(closedError(this.closeInfo));
        this.#inbox.close();
        resolve(this.closeInfo);
      };
    });
    this.#ws.onmessage = (event) => {
      if (typeof event.data !== "string") {
        this.#inbox.push({ binary: new Uint8Array(event.data) });
        return;
      }
      let control;
      try {
        control = JSON.parse(event.data);
      } catch {
        return;
      }
      if (control.type === "ready") {
        settleReady();
        return;
      }
      if (control.type === "error") settleReady(proxyError(control));
      if (control.type === "end") this.#ended = true;
      this.#inbox.push({ control });
    };
    this.#ws.send(JSON.stringify(startMessage));
  }

  get endedCleanly() {
    return this.#ended;
  }

  /** Returns false once the socket is no longer open. */
  sendBinary(bytes) {
    if (this.#ws.readyState !== WebSocket.OPEN) return false;
    this.#ws.send(bytes);
    return true;
  }

  /** Tells the proxy no more input is coming; output keeps flowing until the upstream finishes. */
  end() {
    if (this.#ws.readyState === WebSocket.OPEN) this.#ws.send(JSON.stringify({ type: "end" }));
  }

  close() {
    if (this.#ws.readyState <= WebSocket.OPEN) this.#ws.close(1000);
  }

  /** Messages as { binary: Uint8Array } or { control: object }, until the socket closes. */
  messages() {
    return this.#inbox;
  }
}

async function startStream(startMessage) {
  const stream = new ProxyStream(await pool.acquire(), startMessage);
  return stream;
}

async function* novaResponseBody(stream) {
  try {
    for await (const message of stream.messages()) {
      if (message.binary) {
        yield { chunk: { bytes: message.binary } };
        continue;
      }
      const { control } = message;
      if (control.type === "end") return;
      if (control.type === "error") {
        // Same shape as a Bedrock stream exception member, so the existing parser handles it.
        if (NOVA_STREAM_EXCEPTIONS.has(control.code)) {
          yield { [control.code]: { message: control.message } };
          return;
        }
        throw proxyError(control);
      }
    }
    if (!stream.endedCleanly) throw closedError(stream.closeInfo);
  } finally {
    stream.close();
  }
}

/** Opens connections ahead of the first Start. Call once the agent is signed in. */
export function warmProxyConnections() {
  pool.start();
}

/**
 * Drop-in replacement for BedrockRuntimeClient.send(InvokeModelWithBidirectionalStreamCommand).
 * `outbound` is the adapter's async iterable of { chunk: { bytes } } input events. Resolves once the
 * proxy has the Bedrock stream open, with { body } yielding Bedrock-shaped output events.
 */
export async function openNovaProxyStream(outbound) {
  const stream = await startStream({ type: "start", service: "nova" });

  // Input is sent straight away rather than after "ready": the proxy queues it while Bedrock accepts
  // the stream, which is what the SDK does with the same queue when calling Bedrock directly.
  (async () => {
    for await (const item of outbound) {
      if (!stream.sendBinary(item.chunk.bytes)) break;
    }
    stream.end();
  })().catch((err) => console.warn(`${LOGGER_PREFIX} - Nova Sonic proxy input stopped`, err));

  await stream.ready;
  return { body: novaResponseBody(stream) };
}

/**
 * Starts a Transcribe stream through the proxy WITHOUT waiting for Transcribe to accept it. Send PCM16
 * chunks with sendBinary() straight away, then await `stream.ready`: Transcribe only accepts a stream once
 * audio arrives, so waiting first would never complete. Read { control: { type: "transcript", text } }
 * from messages().
 */
export async function startTranscribeProxyStream({ languageCode, sampleRate }) {
  return startStream({ type: "start", service: "transcribe", languageCode, sampleRate });
}

/**
 * fix 6: the forceBackupTranslation switch, as the proxy last read it from Parameter Store.
 * @returns {Promise<{ forceBackup: boolean }>}
 */
export async function fetchTranslationMode({ timeoutMs = 5000 } = {}) {
  const token = await getAccessToken();
  const abort = new AbortController();
  const timer = setTimeout(() => abort.abort(), timeoutMs);
  try {
    const response = await fetch(new URL(TRANSLATION_MODE_PATH, window.location.origin), {
      method: "GET",
      headers: { Authorization: `Bearer ${token}` },
      credentials: "omit",
      cache: "no-store",
      signal: abort.signal,
    });
    if (!response.ok) throw new Error(`Translation mode request failed: HTTP ${response.status}`);
    const result = await response.json();
    return { forceBackup: result?.forceBackup === true };
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Runs the Translate + Polly fallback server-side.
 * @returns {Promise<{ translatedText: string, audio: Uint8Array|null, audioError: boolean }>}
 */
export async function requestProxyFallback({ text, sourceLanguageCode, targetLanguageCode, voice }) {
  const token = await getAccessToken();
  const response = await fetch(new URL(FALLBACK_PATH, window.location.origin), {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
    body: JSON.stringify({
      text,
      sourceLanguageCode,
      targetLanguageCode,
      ...(voice ? { voiceId: voice.voiceId, engine: voice.engine } : {}),
    }),
    credentials: "omit",
    cache: "no-store",
  });
  if (!response.ok) {
    const detail = await response.json().catch(() => ({}));
    throw new Error(`Translation proxy fallback failed: HTTP ${response.status}${detail.error ? ` (${detail.error})` : ""}`);
  }
  const result = await response.json();
  return {
    translatedText: result.translatedText,
    audio: result.audio ? base64ToArrayBuffer(result.audio) : null,
    audioError: result.audioError === true,
  };
}
