// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import { StartStreamTranscriptionCommand } from "@aws-sdk/client-transcribe-streaming";
import { AsyncQueue } from "../asyncQueue.js";
import { errorFields } from "../logger.js";
import { validatePcmChunk } from "../validation.js";
import { clientErrorMessage, toErrorCode } from "./errors.js";

// Roughly 40 seconds of audio at the webapp's chunk size. Only reached if Transcribe stops reading.
const MAX_BUFFERED_CHUNKS = 500;

/**
 * Bridges one WebSocket to one Transcribe streaming session.
 *
 * Input: binary frames of PCM16 little-endian mono audio at the negotiated sample rate.
 * Output: { type: "transcript", text } for FINAL results only. The webapp discards partial results,
 * so they are dropped here instead of being sent over the wire.
 */
export function createTranscribeSession(conn, { languageCode, sampleRate }, { transcribe, config, logger }) {
  const audio = new AsyncQueue({ maxItems: MAX_BUFFERED_CHUNKS });
  const abort = new AbortController();
  const startedAt = performance.now();
  const metrics = conn.metrics;

  const maxTimer = setTimeout(
    () => conn.fail("sessionTimeout", "Transcribe session exceeded its maximum duration"),
    config.timeouts.transcribeMaxMs,
  );

  async function* audioStream() {
    for await (const chunk of audio) yield { AudioEvent: { AudioChunk: chunk } };
  }

  (async () => {
    let response;
    try {
      response = await transcribe.send(
        new StartStreamTranscriptionCommand({
          LanguageCode: languageCode,
          MediaSampleRateHertz: sampleRate,
          MediaEncoding: "pcm",
          EnablePartialResultsStabilization: true,
          PartialResultsStability: "high",
          AudioStream: audioStream(),
        }),
        { abortSignal: abort.signal },
      );
    } catch (err) {
      if (abort.signal.aborted) return;
      logger.warn("transcribe stream failed to open", { connId: conn.id, ...errorFields(err) });
      const code = toErrorCode(err);
      conn.fail(code, clientErrorMessage(code, err.message));
      return;
    }

    metrics.upstreamReadyMs = Math.round(performance.now() - startedAt);
    conn.sendControl({ type: "ready" });

    try {
      for await (const event of response.TranscriptResultStream) {
        if (!event.TranscriptEvent) {
          // Transcribe names stream members in PascalCase, e.g. { BadRequestException: { Message } }.
          const key = Object.keys(event).find((name) => name !== "$unknown") ?? "UnknownEvent";
          const code = toErrorCode({ name: key });
          logger.warn("transcribe stream exception", { connId: conn.id, errorName: key, errorMessage: event[key]?.Message });
          conn.fail(code, clientErrorMessage(code, event[key]?.Message));
          return;
        }
        for (const result of event.TranscriptEvent.Transcript?.Results ?? []) {
          if (result.IsPartial) continue;
          const text = result.Alternatives?.[0]?.Transcript ?? "";
          if (!text.trim()) continue;
          if (metrics.firstOutputMs == null) metrics.firstOutputMs = Math.round(performance.now() - startedAt);
          conn.sendControl({ type: "transcript", text });
        }
      }
      conn.finish();
    } catch (err) {
      if (abort.signal.aborted) return;
      logger.warn("transcribe stream error", { connId: conn.id, ...errorFields(err) });
      const code = toErrorCode(err);
      conn.fail(code, clientErrorMessage(code, err.message));
    }
  })().finally(() => clearTimeout(maxTimer));

  return {
    onData(bytes) {
      const check = validatePcmChunk(bytes);
      if (!check.ok) {
        conn.fail("invalidAudio", `Rejected audio chunk (${check.reason})`, { protocolError: true });
        return;
      }
      metrics.bytesIn += bytes.length;
      if (!audio.push(bytes)) conn.fail("backpressure", "Transcribe is not consuming audio");
    },
    onEnd() {
      audio.close();
    },
    onClose() {
      clearTimeout(maxTimer);
      audio.close();
      abort.abort();
    },
  };
}
