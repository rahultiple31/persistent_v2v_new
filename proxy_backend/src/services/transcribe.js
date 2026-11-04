// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import { StartStreamTranscriptionCommand } from "@aws-sdk/client-transcribe-streaming";
import { AsyncQueue } from "../asyncQueue.js";
import { errorFields } from "../logger.js";
import { validatePcmChunk } from "../validation.js";
import { clientErrorMessage, toErrorCode } from "./errors.js";
import { createPieceSplitter } from "./transcriptPieces.js";

// Roughly 40 seconds of audio at the webapp's chunk size. Only reached if Transcribe stops reading.
const MAX_BUFFERED_CHUNKS = 500;

// A stream is signed with the credentials current when it opens, and Transcribe ends it once they expire.
// In their last five minutes the SDK refreshes the task role's credentials in the background but still
// hands out the old ones meanwhile, so a stream that opens then can outlive them (2026-10-15, 11:39 UTC:
// "The security token included in the request is expired" three and a half minutes into a stream). A new
// stream picks up the refreshed credentials, so the stream is reopened on the same connection: the webapp
// keeps sending audio and sees no break other than the sentence that was being spoken.
const MAX_CREDENTIAL_REOPENS = 2;
const REOPEN_DELAY_MS = 250;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** True for the error Transcribe ends a stream with when its credentials have expired. */
export function isExpiredCredentialsError(name, message) {
  return /^ExpiredToken/i.test(name || "") || /security token included in the request is expired/i.test(message || "");
}

/**
 * The audio for each upstream stream, read from one queue. When a stream is replaced it stops reading, and a
 * chunk it was waiting for goes to the next stream, so reopening loses no audio. Ending a stream never
 * closes the queue.
 */
function createAudioSource(queue) {
  const source = queue[Symbol.asyncIterator]();
  let pending = null;
  let current = 0;
  return {
    /** The audio events for a new stream; the previous stream gets no more audio. */
    next() {
      const mine = ++current;
      return (async function* () {
        while (mine === current) {
          pending ??= source.next();
          const result = await pending;
          if (mine !== current) return;
          pending = null;
          if (result.done) return;
          yield { AudioEvent: { AudioChunk: result.value } };
        }
      })();
    },
    /** The current stream gets no more audio. */
    retire() {
      current++;
    },
  };
}

/**
 * Bridges one WebSocket to one Transcribe streaming session.
 *
 * Input: binary frames of PCM16 little-endian mono audio at the negotiated sample rate.
 * Output, per sentence:
 *  - { type: "piece", text, words, confidence, wholeSentence } as soon as a part of the sentence up to a
 *    punctuation mark is stable, and the rest when the sentence ends (transcriptPieces.js). The backup
 *    translation speaks these at once, except short ones that look like background noise.
 *  - { type: "transcript", text }: the whole sentence, from the FINAL result, after its last piece.
 * Partial results themselves are not sent: the webapp has no use for them.
 */
export function createTranscribeSession(conn, { languageCode, sampleRate }, { transcribe, config, logger }) {
  const audio = new AsyncQueue({ maxItems: MAX_BUFFERED_CHUNKS });
  const audioSource = createAudioSource(audio);
  const abort = new AbortController();
  const startedAt = performance.now();
  const metrics = conn.metrics;
  const pieces = createPieceSplitter(languageCode);

  function sendText(type, text, about) {
    if (metrics.firstOutputMs == null) metrics.firstOutputMs = Math.round(performance.now() - startedAt);
    conn.sendControl({ type, text, ...about });
  }
  const sendPiece = ({ text, ...about }) => sendText("piece", text, about);

  const maxTimer = setTimeout(
    () => conn.fail("sessionTimeout", "Transcribe session exceeded its maximum duration"),
    config.timeouts.transcribeMaxMs,
  );

  function open() {
    return transcribe.send(
      new StartStreamTranscriptionCommand({
        LanguageCode: languageCode,
        MediaSampleRateHertz: sampleRate,
        MediaEncoding: "pcm",
        EnablePartialResultsStabilization: true,
        PartialResultsStability: "high",
        AudioStream: audioSource.next(),
      }),
      { abortSignal: abort.signal },
    );
  }

  /**
   * Relays one stream's results. Resolves with null when the stream ends normally, or with
   * { name, message, member } when Transcribe ends it with an exception. Throws on a transport error.
   */
  async function relay(response) {
    for await (const event of response.TranscriptResultStream) {
      if (!event.TranscriptEvent) {
        // Transcribe names stream members in PascalCase, e.g. { BadRequestException: { Message } }.
        const key = Object.keys(event).find((name) => name !== "$unknown") ?? "UnknownEvent";
        return { name: key, message: event[key]?.Message, member: true };
      }
      for (const result of event.TranscriptEvent.Transcript?.Results ?? []) {
        if (result.IsPartial) {
          for (const piece of pieces.partial(result)) sendPiece(piece);
          continue;
        }
        const lastPiece = pieces.final(result);
        if (lastPiece) sendPiece(lastPiece);
        const text = result.Alternatives?.[0]?.Transcript ?? "";
        if (!text.trim()) continue;
        sendText("transcript", text);
      }
    }
    return null;
  }

  (async () => {
    let reopens = 0;
    for (;;) {
      let response;
      try {
        response = await open();
      } catch (err) {
        if (abort.signal.aborted) return;
        logger.warn("transcribe stream failed to open", { connId: conn.id, ...errorFields(err) });
        const code = toErrorCode(err);
        conn.fail(code, clientErrorMessage(code, err.message));
        return;
      }

      if (metrics.upstreamReadyMs == null) {
        metrics.upstreamReadyMs = Math.round(performance.now() - startedAt);
        conn.sendControl({ type: "ready" });
      }

      let failure;
      let thrown = null;
      try {
        failure = await relay(response);
      } catch (err) {
        thrown = err;
        failure = { name: err?.name, message: err?.message, member: false };
      }
      if (abort.signal.aborted) return;
      if (!failure) {
        conn.finish();
        return;
      }

      if (isExpiredCredentialsError(failure.name, failure.message) && reopens < MAX_CREDENTIAL_REOPENS) {
        reopens++;
        metrics.upstreamReopens = reopens;
        // Nothing more goes to the stream that ended; the next one starts with the audio after it.
        audioSource.retire();
        logger.warn("transcribe stream credentials expired, reopening", {
          connId: conn.id,
          reopen: reopens,
          errorName: failure.name,
          errorMessage: failure.message,
        });
        await sleep(REOPEN_DELAY_MS);
        if (abort.signal.aborted) return;
        continue;
      }

      if (failure.member) {
        logger.warn("transcribe stream exception", { connId: conn.id, errorName: failure.name, errorMessage: failure.message });
      } else {
        logger.warn("transcribe stream error", { connId: conn.id, ...errorFields(thrown) });
      }
      const code = toErrorCode({ name: failure.name });
      conn.fail(code, clientErrorMessage(code, failure.message));
      return;
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
