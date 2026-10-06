// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import { InvokeModelWithBidirectionalStreamCommand } from "@aws-sdk/client-bedrock-runtime";
import { AsyncQueue } from "../asyncQueue.js";
import { errorFields } from "../logger.js";
import { validateNovaInputEvent } from "../validation.js";
import { clientErrorMessage, toErrorCode } from "./errors.js";

// Roughly 50 seconds of 16 kHz audio frames. Only reached if Bedrock stops reading input.
const MAX_BUFFERED_INPUT_EVENTS = 2000;

// Opening the Bedrock stream normally takes well under a second. An attempt that has not opened after
// OPEN_ATTEMPT_TIMEOUT_MS, or that fails without an AWS error response (a dropped or refused connection),
// is made once more on a new connection. Both attempts fit inside the webapp's 15-second ready timeout.
// The SDK cannot retry this request itself because its body is a live stream.
const MAX_OPEN_ATTEMPTS = 2;
const OPEN_ATTEMPT_TIMEOUT_MS = 6_000;
const OPEN_RETRY_DELAY_MS = 200;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Retried: no response from AWS at all (network errors carry no HTTP status), or an AWS 5xx.
// Never retried: 4xx responses such as access denied, validation and throttling.
function isRetryableOpenError(err) {
  const status = err?.$metadata?.httpStatusCode;
  return status == null || status >= 500;
}

/**
 * The Nova Sonic input for each open attempt. Until the stream is open every event the SDK reads is kept,
 * so a second attempt resends the whole sequence from sessionStart. Only one read from the live queue is
 * outstanding at a time, so an abandoned attempt cannot take an event away from the next one.
 */
class ReplayableInput {
  #source;
  #events = [];
  #read = null;
  #replaying = true;

  constructor(queue) {
    this.#source = queue[Symbol.asyncIterator]();
  }

  /** An iterable of every event from the first one, then the live ones, until `cursor.abandoned`. */
  attempt() {
    const cursor = { index: 0, abandoned: false };
    return { cursor, body: { [Symbol.asyncIterator]: () => ({ next: () => this.#next(cursor) }) } };
  }

  /** The stream opened on this attempt: stop keeping events for a retry. */
  commit(cursor) {
    this.#events.splice(0, cursor.index);
    cursor.index = 0;
    this.#replaying = false;
  }

  async #next(cursor) {
    while (!cursor.abandoned && cursor.index >= this.#events.length) {
      this.#read ??= this.#source.next().then((result) => {
        this.#read = null;
        if (!result.done) this.#events.push(result.value);
        return result;
      });
      if ((await this.#read).done) break;
    }
    if (cursor.abandoned || cursor.index >= this.#events.length) return { value: undefined, done: true };
    if (this.#replaying) return { value: this.#events[cursor.index++], done: false };
    return { value: this.#events.shift(), done: false };
  }
}

/**
 * Bridges one WebSocket to one Nova Sonic bidirectional stream.
 *
 * The webapp builds the Nova Sonic events exactly as it did when it called Bedrock directly; each one
 * arrives as a binary frame of UTF-8 JSON. The proxy checks the envelope and forwards the original bytes,
 * and relays every output event's bytes back unchanged, so neither direction is re-serialised.
 * The model ID comes from the server configuration, never from the client.
 */
export function createNovaSession(conn, { bedrock, config, logger }) {
  const input = new AsyncQueue({ maxItems: MAX_BUFFERED_INPUT_EVENTS });
  const replayable = new ReplayableInput(input);
  const abort = new AbortController();
  const startedAt = performance.now();
  const metrics = conn.metrics;

  const maxTimer = setTimeout(() => conn.fail("sessionTimeout", "Nova Sonic session exceeded its maximum duration"), config.timeouts.novaMaxMs);

  async function open() {
    for (let attempt = 1; ; attempt++) {
      const { cursor, body } = replayable.attempt();
      // Aborted when the connection closes (for the whole stream) or when this attempt times out.
      const attemptAbort = new AbortController();
      const forwardAbort = () => attemptAbort.abort();
      abort.signal.addEventListener("abort", forwardAbort, { once: true });
      let timedOut = false;
      const openTimer = setTimeout(() => {
        timedOut = true;
        attemptAbort.abort();
      }, OPEN_ATTEMPT_TIMEOUT_MS);
      metrics.upstreamOpenAttempts = attempt;
      try {
        const response = await bedrock.send(
          new InvokeModelWithBidirectionalStreamCommand({ modelId: config.novaModelId, body }),
          { abortSignal: attemptAbort.signal },
        );
        replayable.commit(cursor);
        return response;
      } catch (err) {
        cursor.abandoned = true;
        abort.signal.removeEventListener("abort", forwardAbort);
        if (abort.signal.aborted) throw err;
        const fields = { connId: conn.id, attempt, timedOut, ...errorFields(err) };
        if (attempt >= MAX_OPEN_ATTEMPTS || !(timedOut || isRetryableOpenError(err))) {
          logger.warn("nova stream failed to open", fields);
          throw timedOut ? Object.assign(new Error("Timed out opening the Nova Sonic stream"), { name: "TimeoutError" }) : err;
        }
        logger.warn("nova stream open attempt failed, retrying", fields);
        attemptAbort.abort();
        await sleep(OPEN_RETRY_DELAY_MS);
        if (abort.signal.aborted) throw err;
      } finally {
        clearTimeout(openTimer);
      }
    }
  }

  (async () => {
    let response;
    try {
      response = await open();
    } catch (err) {
      if (abort.signal.aborted) return;
      const code = toErrorCode(err);
      conn.fail(code, clientErrorMessage(code, err.message));
      return;
    }

    metrics.upstreamReadyMs = Math.round(performance.now() - startedAt);
    conn.sendControl({ type: "ready" });

    try {
      for await (const event of response.body) {
        if (event.chunk?.bytes) {
          if (metrics.firstOutputMs == null) metrics.firstOutputMs = Math.round(performance.now() - startedAt);
          metrics.bytesOut += event.chunk.bytes.length;
          conn.sendBinary(event.chunk.bytes);
          continue;
        }
        // A modelled exception delivered as a stream member, e.g. { validationException: { message } }.
        const code = Object.keys(event).find((key) => key !== "$unknown") ?? "unknownEvent";
        logger.warn("nova stream exception", { connId: conn.id, errorName: code, errorMessage: event[code]?.message });
        conn.fail(code, clientErrorMessage(code, event[code]?.message));
        return;
      }
      conn.finish();
    } catch (err) {
      if (abort.signal.aborted) return;
      logger.warn("nova stream error", { connId: conn.id, ...errorFields(err) });
      const code = toErrorCode(err);
      conn.fail(code, clientErrorMessage(code, err.message));
    }
  })().finally(() => clearTimeout(maxTimer));

  return {
    onData(bytes) {
      const check = validateNovaInputEvent(bytes);
      if (!check.ok) {
        conn.fail("invalidEvent", `Rejected Nova Sonic input event (${check.reason})`, { protocolError: true });
        return;
      }
      metrics.bytesIn += bytes.length;
      if (!input.push({ chunk: { bytes } })) conn.fail("backpressure", "Nova Sonic is not consuming input");
    },
    onEnd() {
      input.close();
    },
    onClose() {
      clearTimeout(maxTimer);
      input.close();
      abort.abort();
    },
  };
}
