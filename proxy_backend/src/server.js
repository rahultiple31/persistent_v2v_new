// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
//
// WebSocket protocol (path /ws), one upstream stream per connection:
//
//   client -> {"type":"auth","token":"<access token>"}                  first frame, never in the URL
//             (AUTH_MODE=bff: {"type":"auth"}; the user comes from the session cookie of the upgrade)
//   client -> {"type":"start","service":"nova"}
//          or {"type":"start","service":"transcribe","languageCode":"en-US","sampleRate":16000}
//   client -> binary frames                                               Nova Sonic event JSON / PCM16 audio
//   client -> {"type":"end"}                                              no more input
//   server -> {"type":"ready"}                                            upstream stream established
//   server -> binary frames (Nova Sonic output events), or for Transcribe {"type":"piece","text":"...",
//             "words":n,"confidence":0-1|null,"wholeSentence":bool} (part of a sentence, sent while it is
//             still spoken) and {"type":"transcript","text":"..."}
//   server -> {"type":"error","code":"...","message":"..."} then close, or {"type":"end"} then close
//
// The client may send auth, start and its first data frames back to back without waiting: frames that
// arrive while the token is being verified are queued and replayed in order, so authentication never
// costs an extra round trip.
import http from "node:http";
import https from "node:https";
import { randomUUID } from "node:crypto";
import { WebSocket, WebSocketServer } from "ws";
import { ConnectionLimiter, RateLimiter } from "./limits.js";
import { errorFields } from "./logger.js";
import { parseControlMessage, validateFallbackRequest, validateTranscribeStart } from "./validation.js";
import { createNovaSession } from "./services/nova.js";
import { createTranscribeSession } from "./services/transcribe.js";
import { runFallback } from "./services/fallback.js";
import { createSite } from "./site.js";

export const CLOSE_CODES = Object.freeze({
  NORMAL: 1000,
  INTERNAL_ERROR: 1011,
  SERVICE_RESTART: 1012,
  TRY_AGAIN_LATER: 1013,
  BAD_REQUEST: 4400,
  UNAUTHORIZED: 4401,
  TOO_MANY_CONNECTIONS: 4429,
});

const WS_PATH = "/ws";
const FALLBACK_PATH = "/api/fallback";
const TRANSLATION_MODE_PATH = "/api/translation-mode";
const TEST_SIGN_IN_PATH = "/api/test-sign-in";
const HEALTH_PATH = "/healthz";
const API_PREFIX = "/api/";
const MAX_WS_PAYLOAD_BYTES = 256 * 1024;
const MAX_FRAMES_WHILE_AUTHENTICATING = 256;
const MAX_FALLBACK_BODY_BYTES = 16 * 1024;
const MAX_TEST_SIGN_IN_BODY_BYTES = 1024;
const TEST_SIGN_IN_ATTEMPTS_PER_MINUTE = 10;
const TEST_NAME = /^[A-Za-z0-9 ._-]{1,40}$/;
const CLOSE_HANDSHAKE_TIMEOUT_MS = 5_000;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
// aws-jwt-verify's errors are all named "Error"; their class says why a token was rejected (issuer, audience, expiry...).
const authErrorName = (err) => (err?.name && err.name !== "Error" ? err.name : err?.constructor?.name);

class ProxyConnection {
  id = randomUUID();
  metrics = { bytesIn: 0, bytesOut: 0, upstreamReadyMs: null, firstOutputMs: null };
  closed;

  #ws;
  #deps;
  #state = "awaitingAuth"; // -> authenticating -> authenticated -> started -> closing -> closed
  #pending = [];
  #identity = null;
  #service = null;
  #session = null;
  #timer = null;
  #alive = true;
  #closeReason = null;
  #openedAt = performance.now();
  #startedAt = null;
  #resolveClosed;

  constructor(ws, deps) {
    this.#ws = ws;
    this.#deps = deps;
    this.closed = new Promise((resolve) => {
      this.#resolveClosed = resolve;
    });
    this.#timer = setTimeout(() => this.#close(CLOSE_CODES.UNAUTHORIZED, "authTimeout"), deps.config.timeouts.authMs);
    ws.on("message", (data, isBinary) => this.#onMessage(data, isBinary));
    ws.on("pong", () => {
      this.#alive = true;
    });
    ws.on("close", (code) => this.#onClosed(code));
    ws.on("error", (err) => deps.logger.warn("websocket error", { connId: this.id, ...errorFields(err) }));
  }

  get started() {
    return this.#state === "started";
  }

  heartbeat() {
    if (!this.#alive) {
      this.#ws.terminate();
      return;
    }
    this.#alive = false;
    this.#ws.ping();
  }

  /** Closes with 1012 so the client reconnects, and the load balancer routes it to a healthy task. */
  drain() {
    this.#close(CLOSE_CODES.SERVICE_RESTART, "serverRestart");
  }

  // ── Called by the service sessions ──────────────────────────────────────

  sendBinary(bytes) {
    if (this.#ws.readyState === WebSocket.OPEN) this.#ws.send(bytes, { binary: true });
  }

  sendControl(message) {
    if (this.#ws.readyState === WebSocket.OPEN) this.#ws.send(JSON.stringify(message));
  }

  finish() {
    this.sendControl({ type: "end" });
    this.#close(CLOSE_CODES.NORMAL, "done");
  }

  fail(code, message, { protocolError = false } = {}) {
    if (this.#state === "closing" || this.#state === "closed") return;
    this.sendControl({ type: "error", code, message });
    this.#close(protocolError ? CLOSE_CODES.BAD_REQUEST : CLOSE_CODES.INTERNAL_ERROR, code);
  }

  // ── Protocol ────────────────────────────────────────────────────────────

  #onMessage(data, isBinary) {
    switch (this.#state) {
      case "awaitingAuth":
        this.#authenticate(data, isBinary);
        return;
      case "authenticating":
        if (this.#pending.length >= MAX_FRAMES_WHILE_AUTHENTICATING) {
          this.#protocolError("tooManyFramesBeforeAuth");
          return;
        }
        this.#pending.push([data, isBinary]);
        return;
      case "authenticated":
        this.#start(data, isBinary);
        return;
      case "started":
        this.#onStreamMessage(data, isBinary);
        return;
      default:
        // closing / closed: drop
    }
  }

  #authenticate(data, isBinary) {
    const message = isBinary ? null : parseControlMessage(data);
    const tokenMissing = typeof message?.token !== "string" || !message.token;
    if (message?.type !== "auth" || (tokenMissing && !this.#deps.cookieSession)) {
      this.#close(CLOSE_CODES.UNAUTHORIZED, "authRequired");
      return;
    }
    this.#state = "authenticating";
    this.#deps.verifier.verify(message.token).then(
      (identity) => this.#onAuthenticated(identity),
      (err) => {
        this.#deps.logger.info("websocket auth rejected", { connId: this.id, errorName: authErrorName(err) });
        this.#close(CLOSE_CODES.UNAUTHORIZED, "unauthorized");
      },
    );
  }

  #onAuthenticated(identity) {
    if (this.#state !== "authenticating") return; // closed while verifying
    if (!this.#deps.limiter.tryAcquireUser(identity.userId)) {
      this.#deps.logger.warn("per-user connection limit reached", { connId: this.id, userId: identity.userId });
      this.#close(CLOSE_CODES.TOO_MANY_CONNECTIONS, "tooManyConnections");
      return;
    }
    this.#identity = identity;
    this.#state = "authenticated";
    clearTimeout(this.#timer);
    this.#timer = setTimeout(() => this.#close(CLOSE_CODES.NORMAL, "idleTimeout"), this.#deps.config.timeouts.idleUnstartedMs);

    const pending = this.#pending;
    this.#pending = [];
    for (const [data, isBinary] of pending) this.#onMessage(data, isBinary);
  }

  #start(data, isBinary) {
    const message = isBinary ? null : parseControlMessage(data);
    if (message?.type !== "start") {
      this.#protocolError("startRequired");
      return;
    }
    // A pooled socket may have been authenticated a while ago.
    if (Date.now() >= this.#identity.expiresAt) {
      this.#close(CLOSE_CODES.UNAUTHORIZED, "tokenExpired");
      return;
    }

    const { config, logger, clients } = this.#deps;
    let transcribeParams;
    if (message.service === "transcribe") {
      const check = validateTranscribeStart(message);
      if (!check.ok) {
        this.#protocolError(check.reason);
        return;
      }
      transcribeParams = check.value;
    } else if (message.service !== "nova") {
      this.#protocolError("unknownService");
      return;
    }

    clearTimeout(this.#timer);
    this.#service = message.service;
    this.#state = "started";
    this.#startedAt = performance.now();
    this.#session =
      message.service === "nova"
        ? createNovaSession(this, { bedrock: clients.bedrock, config, logger })
        : createTranscribeSession(this, transcribeParams, { transcribe: clients.transcribe, config, logger });
  }

  #onStreamMessage(data, isBinary) {
    if (isBinary) {
      this.#session.onData(data);
      return;
    }
    if (parseControlMessage(data)?.type === "end") {
      this.#session.onEnd();
      return;
    }
    this.#protocolError("unexpectedMessage");
  }

  #protocolError(reason) {
    this.fail("protocolError", reason, { protocolError: true });
  }

  #close(code, reason) {
    if (this.#state === "closing" || this.#state === "closed") return;
    this.#state = "closing";
    this.#closeReason = reason;
    clearTimeout(this.#timer);
    this.#session?.onClose();
    this.#ws.close(code, reason);
    setTimeout(() => this.#ws.terminate(), CLOSE_HANDSHAKE_TIMEOUT_MS).unref();
  }

  #onClosed(code) {
    this.#state = "closed";
    clearTimeout(this.#timer);
    this.#session?.onClose();
    if (this.#identity) this.#deps.limiter.releaseUser(this.#identity.userId);
    const now = performance.now();
    this.#deps.logger.info("websocket closed", {
      connId: this.id,
      userId: this.#identity?.userId,
      service: this.#service,
      closeCode: code,
      closeReason: this.#closeReason ?? "clientClosed",
      connectionMs: Math.round(now - this.#openedAt),
      sessionMs: this.#startedAt == null ? null : Math.round(now - this.#startedAt),
      ...this.metrics,
    });
    this.#resolveClosed();
  }
}

function sendJson(res, status, body, headers = {}) {
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

function rejectUpgrade(socket, status, statusText) {
  socket.end(`HTTP/1.1 ${status} ${statusText}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);
}

function bearerToken(header) {
  const match = /^Bearer ([A-Za-z0-9\-_.]+)$/.exec(header || "");
  return match ? match[1] : null;
}

class BodyTooLargeError extends Error {}

function readBody(req, limit) {
  return new Promise((resolve, reject) => {
    if (Number(req.headers["content-length"]) > limit) {
      req.resume();
      reject(new BodyTooLargeError());
      return;
    }
    const chunks = [];
    let size = 0;
    let tooLarge = false;
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > limit) tooLarge = true;
      else chunks.push(chunk);
    });
    req.on("end", () => (tooLarge ? reject(new BodyTooLargeError()) : resolve(Buffer.concat(chunks).toString("utf8"))));
    req.on("error", reject);
  });
}

/**
 * Creates the proxy's HTTP + WebSocket server. Dependencies are injected so tests can replace the token
 * verifier and the AWS clients.
 *
 * @param {object} deps
 * @param {object} deps.config   - from loadConfig()
 * @param {{verify(token: string): Promise<{userId: string, expiresAt: number}>}} deps.verifier
 * @param {{bedrock, transcribe, translate, polly}} deps.clients - AWS SDK v3 clients
 * @param {object} deps.logger   - from createLogger()
 * @param {{current(): {forceBackup: boolean}}} [deps.translationMode] - fix 6: the forceBackupTranslation
 *   switch (services/translationMode.js). Without it the switch is off.
 * @param {object} [deps.testSignIn] - the temporary test sign-in (services/testSignIn.js). Without it
 *   /api/test-sign-in does not exist.
 * @param {object} [deps.sessionAuth] - AUTH_MODE=bff (sessionAuth.js): /auth/*, the redirect back from the
 *   identity provider, and the session cookie in place of `verifier` for /ws and /api.
 * @param {{key: string, cert: string}} [deps.tls] - SERVER_TLS=self-signed (selfSignedCert.js): serve HTTPS.
 *   Without it the server speaks plain HTTP.
 */
export function createProxyServer({ config, verifier, clients, logger, translationMode = null, testSignIn = null, sessionAuth = null, tls = null }) {
  const limiter = new ConnectionLimiter({
    maxTotal: config.limits.maxConnections,
    maxPerUser: config.limits.maxConnectionsPerUser,
  });
  const fallbackLimiter = new RateLimiter({ perMinute: config.limits.fallbackRequestsPerMinute });
  const testSignInLimiter = new RateLimiter({ perMinute: TEST_SIGN_IN_ATTEMPTS_PER_MINUTE });
  const connections = new Set();
  const connectionDeps = { config, verifier, clients, logger, limiter };
  // The proxy also serves the webapp (config.site), on the same origin as /ws and /api.
  const site = config.site ? createSite(config.site) : null;
  let draining = false;

  const isOriginAllowed = (origin) => config.allowedOrigins.length === 0 || config.allowedOrigins.includes(origin);

  /**
   * The signed-in user of an /api request, or null after answering it. AUTH_MODE=bff: the session cookie,
   * plus the fixed request header that only the site's own pages send (sessionAuth.js). Otherwise: the
   * bearer token.
   */
  async function authenticate(req, res, label) {
    if (sessionAuth) {
      if (!sessionAuth.hasRequestHeader(req)) {
        sendJson(res, 403, { error: "requestHeaderMissing" });
        return null;
      }
      try {
        return await sessionAuth.identify(req);
      } catch (err) {
        logger.info(`${label} auth rejected`, { errorName: authErrorName(err) });
        sendJson(res, 401, { error: "unauthorized" });
        return null;
      }
    }
    const token = bearerToken(req.headers.authorization);
    // 401 for every token problem (missing, invalid, expired): the webapp then signs in again.
    if (!token) {
      sendJson(res, 401, { error: "unauthorized" }, { "WWW-Authenticate": "Bearer" });
      return null;
    }
    try {
      return await verifier.verify(token);
    } catch (err) {
      logger.info(`${label} auth rejected`, { errorName: authErrorName(err) });
      sendJson(res, 401, { error: "unauthorized" }, { "WWW-Authenticate": 'Bearer error="invalid_token"' });
      return null;
    }
  }

  async function handleFallback(req, res) {
    const startedAt = performance.now();
    const identity = await authenticate(req, res, "fallback");
    if (!identity) return;
    if (!fallbackLimiter.tryTake(identity.userId)) {
      return sendJson(res, 429, { error: "rateLimited" }, { "Retry-After": "5" });
    }
    if (!/^application\/json\b/i.test(req.headers["content-type"] || "")) {
      return sendJson(res, 415, { error: "unsupportedMediaType" });
    }

    let body;
    try {
      body = JSON.parse(await readBody(req, MAX_FALLBACK_BODY_BYTES));
    } catch (err) {
      return err instanceof BodyTooLargeError
        ? sendJson(res, 413, { error: "bodyTooLarge" })
        : sendJson(res, 400, { error: "invalidJson" });
    }
    const check = validateFallbackRequest(body);
    if (!check.ok) return sendJson(res, 400, { error: check.reason });

    const result = await runFallback(check.value, {
      translate: clients.translate,
      polly: clients.polly,
      logger,
      logContext: { userId: identity.userId },
    });
    sendJson(res, result.status, result.body);
    logger.info("fallback request", {
      userId: identity.userId,
      status: result.status,
      durationMs: Math.round(performance.now() - startedAt),
      textChars: check.value.text.length,
      withAudio: result.body.audio != null,
    });
  }

  // fix 6: the forceBackupTranslation switch, for any signed-in user of the webapp.
  async function handleTranslationMode(req, res) {
    if (!(await authenticate(req, res, "translation mode"))) return;
    const forceBackup = translationMode?.current?.().forceBackup === true;
    return sendJson(res, 200, { forceBackup });
  }

  // The temporary test sign-in: GET says whether it is on (the webapp then shows the password form), POST
  // exchanges the test password for an access token (AUTH_MODE=bff: for a session cookie).
  async function handleTestSignIn(req, res) {
    if (req.method === "GET") return sendJson(res, 200, { enabled: testSignIn.on });
    // A forged sign-in from another site would sign the browser in as a tester (login CSRF).
    if (sessionAuth && !sessionAuth.hasRequestHeader(req)) return sendJson(res, 403, { error: "requestHeaderMissing" });
    // The load balancer appends the address it received the request from as the last entry.
    const client = String(req.headers["x-forwarded-for"] || req.socket.remoteAddress || "").split(",").at(-1).trim();
    if (!testSignInLimiter.tryTake(client)) return sendJson(res, 429, { error: "rateLimited" }, { "Retry-After": "60" });
    if (!/^application\/json\b/i.test(req.headers["content-type"] || "")) return sendJson(res, 415, { error: "unsupportedMediaType" });
    let body;
    try {
      body = JSON.parse(await readBody(req, MAX_TEST_SIGN_IN_BODY_BYTES));
    } catch (err) {
      return err instanceof BodyTooLargeError ? sendJson(res, 413, { error: "bodyTooLarge" }) : sendJson(res, 400, { error: "invalidJson" });
    }
    const name = typeof body?.name === "string" && body.name.trim() ? body.name.trim() : "tester";
    if (!TEST_NAME.test(name)) return sendJson(res, 400, { error: "invalidName" });
    if (!testSignIn.on) return sendJson(res, 404, { error: "testSignInOff" });
    if (sessionAuth) {
      if (!testSignIn.check(body?.password)) {
        logger.warn("test sign-in rejected", { name, client });
        return sendJson(res, 401, { error: "wrongPassword" });
      }
      let started;
      try {
        started = sessionAuth.testSession(name);
      } catch (err) {
        logger.error("test sign-in could not start a session", errorFields(err));
        return sendJson(res, 503, { error: "sessionUnavailable" });
      }
      logger.info("test sign-in", { name, client });
      return sendJson(res, 200, { signedIn: true, test: true, expiresAt: started.expiresAt }, { "Set-Cookie": started.cookie });
    }
    const session = testSignIn.signIn({ password: body?.password, name });
    if (!session) {
      logger.warn("test sign-in rejected", { name, client });
      return sendJson(res, 401, { error: "wrongPassword" });
    }
    logger.info("test sign-in", { name, client });
    return sendJson(res, 200, session);
  }

  async function handleHttp(req, res) {
    const url = new URL(req.url, "http://localhost");
    const { pathname } = url;
    if (pathname === HEALTH_PATH) {
      if (req.method !== "GET" && req.method !== "HEAD") return sendJson(res, 405, { error: "methodNotAllowed" }, { Allow: "GET, HEAD" });
      return sendJson(res, draining ? 503 : 200, { status: draining ? "draining" : "ok" });
    }
    if (pathname === FALLBACK_PATH) {
      if (req.method !== "POST") return sendJson(res, 405, { error: "methodNotAllowed" }, { Allow: "POST" });
      return handleFallback(req, res);
    }
    if (pathname === TRANSLATION_MODE_PATH) {
      if (req.method !== "GET") return sendJson(res, 405, { error: "methodNotAllowed" }, { Allow: "GET" });
      return handleTranslationMode(req, res);
    }
    if (pathname === TEST_SIGN_IN_PATH && testSignIn) {
      if (req.method !== "GET" && req.method !== "POST") return sendJson(res, 405, { error: "methodNotAllowed" }, { Allow: "GET, POST" });
      return handleTestSignIn(req, res);
    }
    if (sessionAuth && (await sessionAuth.handle(req, res, url))) return;
    if (site && pathname !== WS_PATH && !pathname.startsWith(API_PREFIX)) return site.handle(req, res, pathname);
    return sendJson(res, 404, { error: "notFound" });
  }

  const onRequest = (req, res) => {
    handleHttp(req, res).catch((err) => {
      logger.error("http request failed", errorFields(err));
      if (!res.headersSent) sendJson(res, 500, { error: "internalError" });
      else res.destroy();
    });
  };
  // tls (SERVER_TLS=self-signed): HTTPS with the task's own certificate, so the hop from the load balancer is encrypted.
  const server = tls ? https.createServer({ key: tls.key, cert: tls.cert, minVersion: "TLSv1.2" }, onRequest) : http.createServer(onRequest);
  // Longer than the load balancer's idle timeout (120 s), so the load balancer, not Node, closes idle
  // keep-alive connections and never sends a request down a socket Node is closing.
  server.keepAliveTimeout = 125_000;
  server.headersTimeout = 130_000;
  server.requestTimeout = 60_000;

  // perMessageDeflate off: audio does not compress, and compression adds CPU time to every frame.
  const wss = new WebSocketServer({ noServer: true, maxPayload: MAX_WS_PAYLOAD_BYTES, perMessageDeflate: false, clientTracking: false });

  server.on("upgrade", (req, socket, head) => {
    socket.on("error", () => socket.destroy());
    const { pathname } = new URL(req.url, "http://localhost");
    if (pathname !== WS_PATH) return rejectUpgrade(socket, 404, "Not Found");
    if (draining) return rejectUpgrade(socket, 503, "Service Unavailable");
    if (!isOriginAllowed(req.headers.origin)) {
      logger.warn("websocket origin rejected", { origin: req.headers.origin });
      return rejectUpgrade(socket, 403, "Forbidden");
    }
    wss.handleUpgrade(req, socket, head, (ws) => {
      if (!limiter.tryAcquireConnection()) {
        ws.close(CLOSE_CODES.TRY_AGAIN_LATER, "serverBusy");
        return;
      }
      // AUTH_MODE=bff: the user is the session cookie's, sent with the upgrade (checked when the auth frame arrives).
      const deps = sessionAuth ? { ...connectionDeps, cookieSession: true, verifier: { verify: () => sessionAuth.identify(req) } } : connectionDeps;
      const conn = new ProxyConnection(ws, deps);
      connections.add(conn);
      conn.closed.then(() => {
        connections.delete(conn);
        limiter.releaseConnection();
      });
    });
  });

  const heartbeat = setInterval(() => {
    for (const conn of connections) conn.heartbeat();
    fallbackLimiter.prune();
    testSignInLimiter.prune();
  }, config.timeouts.heartbeatMs);
  heartbeat.unref();

  return {
    server,
    siteFileCount: site?.fileCount ?? 0,
    get connectionCount() {
      return connections.size;
    },

    listen(port = config.port, host) {
      return new Promise((resolve, reject) => {
        server.once("error", reject);
        server.listen(port, host, () => {
          server.off("error", reject);
          resolve(server.address());
        });
      });
    },

    /**
     * Graceful shutdown for ECS: fail health checks, move idle pooled sockets to other tasks straight
     * away, give active sessions until the drain timeout to finish, then close the rest with 1012.
     */
    async shutdown() {
      if (draining) return;
      draining = true;
      logger.info("draining", { connections: connections.size });
      server.close();
      for (const conn of connections) if (!conn.started) conn.drain();

      const deadline = Date.now() + config.timeouts.drainMs;
      while (connections.size > 0 && Date.now() < deadline) await sleep(250);

      for (const conn of connections) conn.drain();
      await Promise.race([Promise.all([...connections].map((conn) => conn.closed)), sleep(CLOSE_HANDSHAKE_TIMEOUT_MS)]);
      clearInterval(heartbeat);
      server.closeAllConnections();
      logger.info("drained", { remainingConnections: connections.size });
    },
  };
}
