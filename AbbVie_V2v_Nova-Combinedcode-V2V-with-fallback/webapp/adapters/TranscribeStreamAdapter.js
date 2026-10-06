// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0

/**
 * TranscribeStreamAdapter
 *
 * Provides reliable, language-stable transcription of the agent's speech
 * using AWS Transcribe Streaming — replacing Nova Sonic's USER-role textOutput
 * for the "Agent Said" box.
 *
 * WHY:
 *   Nova Sonic's context becomes contaminated after the first translation cycle,
 *   causing it to emit the *translated* language in the USER role (e.g. Spanish
 *   appearing in the "Agent Said" box instead of English).
 *   AWS Transcribe Streaming always outputs in the declared source language —
 *   no context contamination is possible.
 *
 * HOW:
 *   - Accepts the existing MicWorkletStream's MediaStream (via getMediaStream()).
 *   - Creates its own independent AudioWorkletNode on the same MediaStream so
 *     NO second getUserMedia() call is needed — same physical mic, two consumers.
 *   - Reuses the existing mic-processor.js AudioWorklet (already registered by
 *     MicWorkletStream.create() before this adapter starts).
 *   - Encodes audio with the same filtering downsampler as Nova Sonic
 *     (createPcm16Downsampler) — zero new encoding logic.
 *   - Feeds PCM16 chunks to StartStreamTranscriptionCommand as AudioEvent objects.
 *   - Filters TranscriptResultStream for IsPartial === false (final results only)
 *     to avoid UI flicker.
 *   - Uses the same Cognito credentials already obtained by getValidAwsCredentials().
 *
 * USAGE:
 *   const adapter = new TranscribeStreamAdapter({ ... });
 *   await adapter.start();
 *   // ... call is active ...
 *   await adapter.stop();
 */

import { LOGGER_PREFIX } from "../constants";
import { PROXY_CONFIG } from "../config";
import { getValidAwsCredentials } from "../utils/authUtility";
import { createPcm16Downsampler } from "../utils/novaSonicAudioUtils";
import { startTranscribeProxyStream } from "../utils/proxyTransport";

const WORKLET_URL = new URL("../worklets/mic-processor.js", import.meta.url);
const TRANSCRIBE_SAMPLE_RATE = 16000;
const MAX_START_ATTEMPTS = 3;
// About 17 seconds of audio at the worklet's 4096-sample chunks. Bounds memory if nothing is reading.
const MAX_QUEUED_CHUNKS = 200;
// Consecutive proxy reconnects allowed before giving up; the count resets after a minute of streaming.
const MAX_PROXY_RECONNECTS = 5;
const PROXY_STABLE_STREAM_MS = 60_000;

/**
 * Maps Nova Sonic / internal language codes (e.g. "en", "es") to
 * BCP-47 codes required by AWS Transcribe (e.g. "en-US", "es-US").
 * Extend this table as new languages are added to NOVA_INTERPRETER_LANGUAGES.
 */
const TRANSCRIBE_LANGUAGE_MAP = {
  en:    "en-US",
  es:    "es-US",
  fr:    "fr-FR",
  de:    "de-DE",
  it:    "it-IT",
  pt:    "pt-BR",
  ja:    "ja-JP",
  ko:    "ko-KR",
  zh:    "zh-CN",
  ar:    "ar-SA",
  hi:    "hi-IN",
  nl:    "nl-NL",
  ru:    "ru-RU",
  tr:    "tr-TR",
  pl:    "pl-PL",
  sv:    "sv-SE",
  da:    "da-DK",
  fi:    "fi-FI",
  nb:    "nb-NO",
  // Previously missing, so these silently transcribed as en-US and poisoned
  // the drift baseline with garbage English for a non-English agent.
  cs:    "cs-CZ",
  id:    "id-ID",
  uk:    "uk-UA",
  "pt-PT": "pt-PT",
  "pt-BR": "pt-BR",
  "zh-TW": "zh-TW",
};

function toTranscribeLanguageCode(novaSonicCode) {
  if (!novaSonicCode) return "en-US";
  // If it already looks like a full BCP-47 code (e.g. "en-US"), pass through
  if (novaSonicCode.includes("-") && novaSonicCode.length > 4) return novaSonicCode;
  const mapped = TRANSCRIBE_LANGUAGE_MAP[novaSonicCode];
  if (!mapped) {
    // Falling back to en-US quietly means the agent's speech is transcribed as
    // English, which corrupts the drift baseline rather than merely missing it.
    // Keep the fallback (a wrong baseline still beats no adapter) but say so.
    console.error(
      `${LOGGER_PREFIX} - TranscribeStreamAdapter: no Transcribe mapping for language ` +
      `"${novaSonicCode}" — falling back to en-US, drift baseline will be unreliable`
    );
    return "en-US";
  }
  return mapped;
}

export class TranscribeStreamAdapter {
  /**
   * @param {Object}      opts
   * @param {AudioContext} opts.audioContext      - Shared AudioContext (from AudioContextManager)
   * @param {MediaStream}  opts.micMediaStream    - The mic MediaStream from MicWorkletStream.getMediaStream()
   * @param {string}       opts.languageCode      - Agent's source language (Nova Sonic code, e.g. "en")
   * @param {string}       opts.region            - AWS region for Transcribe Streaming
   * @param {Function}     opts.onTranscript      - Called with final transcript string
   * @param {Function}     [opts.onError]         - Called on unrecoverable error
   */
  constructor({ audioContext, micMediaStream, languageCode, region, onTranscript, onError }) {
    this._audioContext   = audioContext;
    this._micMediaStream = micMediaStream;
    this._languageCode   = toTranscribeLanguageCode(languageCode);
    this._region         = region;
    this._onTranscript   = onTranscript;
    this._onError        = onError ?? ((e) => console.error(`${LOGGER_PREFIX} - TranscribeStreamAdapter error`, e));

    this._stopped        = false;
    this._sourceNode     = null;
    this._workletNode    = null;

    // Queue for async generator that feeds audio to Transcribe
    this._chunkQueue     = [];
    this._chunkResolve   = null;
  }

  /**
   * Start capturing mic audio and streaming it to AWS Transcribe.
   * Resolves once the Transcribe connection is established.
   */
  async start() {
    this._stopped = false;

    // --- 1. Register mic-processor worklet (no-op if already registered) ---
    try {
      await this._audioContext.audioWorklet.addModule(WORKLET_URL);
    } catch (e) {
      if (!e.message?.includes("already")) throw e;
    }

    // --- 2. Create a second AudioWorkletNode on the same MediaStream ---
    //        This gives Transcribe its own audio pipeline without a second
    //        getUserMedia() call — same physical mic, independent consumer.
    this._sourceNode = this._audioContext.createMediaStreamSource(this._micMediaStream);
    this._workletNode = new AudioWorkletNode(this._audioContext, "mic-processor", {
      processorOptions: { bufferSize: 4096 },
      numberOfInputs: 1,
      numberOfOutputs: 1,
      outputChannelCount: [1],
    });

    // Wire: mic source → worklet (capture only, not connected to destination)
    this._sourceNode.connect(this._workletNode);

    // Forward worklet chunks into the async generator queue
    this._workletNode.port.onmessage = (event) => {
      if (this._stopped) return;
      const chunk = event.data.audioChunk; // Float32Array
      if (this._chunkResolve) {
        const resolve = this._chunkResolve;
        this._chunkResolve = null;
        resolve({ value: chunk, done: false });
      } else {
        if (this._chunkQueue.length >= MAX_QUEUED_CHUNKS) this._chunkQueue.shift();
        this._chunkQueue.push(chunk);
      }
    };

    if (PROXY_CONFIG.enabled) {
      await this._startViaProxy();
      return;
    }

    // --- 3. Build AWS Transcribe client with fresh Cognito credentials ---
    const [credentials, { TranscribeStreamingClient, StartStreamTranscriptionCommand }] = await Promise.all([
      getValidAwsCredentials(),
      import("@aws-sdk/client-transcribe-streaming"),
    ]);
    const client = new TranscribeStreamingClient({
      region: this._region,
      credentials: {
        accessKeyId:     credentials.accessKeyId,
        secretAccessKey: credentials.secretAccessKey,
        sessionToken:    credentials.sessionToken,
      },
    });

    // --- 4. Send StartStreamTranscriptionCommand ---
    const command = new StartStreamTranscriptionCommand({
      LanguageCode:                    this._languageCode,
      MediaSampleRateHertz:            TRANSCRIBE_SAMPLE_RATE,
      MediaEncoding:                   "pcm",
      EnablePartialResultsStabilization: true,
      PartialResultsStability:         "high",
      AudioStream:                     this._audioGenerator(),
    });

    // A failure here used to `return` silently. That is far more damaging than
    // it looks: accumulated.user in main.js is fed exclusively by this adapter,
    // and it is both the drift/refusal baseline AND the source text the
    // Translate+Polly fallback needs. If this stream never starts, the guard is
    // disarmed and the fallback has nothing to translate — untranslated audio
    // then reaches the customer for the rest of the call with nothing logged.
    // Retry, and make a final failure loud.
    let response;
    for (let attempt = 1; attempt <= MAX_START_ATTEMPTS; attempt++) {
      try {
        response = await client.send(command);
        break;
      } catch (e) {
        if (this._stopped) return;
        if (attempt === MAX_START_ATTEMPTS) {
          console.error(
            `${LOGGER_PREFIX} - TranscribeStreamAdapter failed to start after ` +
            `${MAX_START_ATTEMPTS} attempts — drift baseline unavailable`,
            e
          );
          this._onError(e);
          return;
        }
        const backoffMs = attempt * 1000;
        console.warn(
          `${LOGGER_PREFIX} - TranscribeStreamAdapter start attempt ${attempt}/${MAX_START_ATTEMPTS} ` +
          `failed, retrying in ${backoffMs}ms`,
          e
        );
        await new Promise((r) => setTimeout(r, backoffMs));
      }
    }
    if (!response) return;

    // --- 5. Process response stream (runs until stop() is called) ---
    this._processResponseStream(response.TranscriptResultStream).catch((e) => {
      if (!this._stopped) this._onError(e);
    });

    console.info(`${LOGGER_PREFIX} - TranscribeStreamAdapter started (lang: ${this._languageCode})`);
  }

  /**
   * Stop capturing and close the Transcribe stream gracefully.
   */
  async stop() {
    if (this._stopped) return;
    this._stopped = true;

    console.info(`${LOGGER_PREFIX} - TranscribeStreamAdapter stopping`);

    // Unblock the async generator so it returns done → AudioStream ends →
    // Transcribe closes the response stream naturally.
    if (this._chunkResolve) {
      this._chunkResolve({ value: undefined, done: true });
      this._chunkResolve = null;
    }

    // Tear down the AudioWorklet pipeline
    try { this._workletNode?.port.close(); }   catch { /* ignore */ }
    try { this._workletNode?.disconnect(); }    catch { /* ignore */ }
    try { this._sourceNode?.disconnect(); }     catch { /* ignore */ }

    this._workletNode = null;
    this._sourceNode  = null;
    this._chunkQueue  = [];
  }

  // ---------------------------------------------------------------------------
  // Proxy transport (PROXY_CONFIG.enabled)
  //
  // Audio goes to the proxy as binary PCM16 frames and the proxy returns FINAL
  // transcripts only. If the proxy closes the stream underneath us (a task being
  // replaced during a deployment closes with 1012), the adapter reconnects and
  // keeps reading the same audio queue, so a deployment costs a moment of
  // transcript instead of ending transcription for the rest of the call.
  // ---------------------------------------------------------------------------

  async _startViaProxy() {
    this._audioIterator = this._audioGenerator();
    const session = await this._connectProxy();
    if (!session) return;
    this._runProxy(session).catch((e) => {
      if (!this._stopped) this._onError(e);
    });
    console.info(`${LOGGER_PREFIX} - TranscribeStreamAdapter started via proxy (lang: ${this._languageCode})`);
  }

  /**
   * Opens a proxy stream and feeds it audio straight away. Transcribe only
   * accepts a stream once audio arrives, so waiting for "ready" before sending
   * audio never completes: that is what timed out every attempt after 15 s.
   * The direct path never hit this because the SDK starts reading the audio
   * generator as soon as the request is sent.
   * Resolves once Transcribe has accepted the stream.
   */
  async _openProxySession() {
    const stream = await startTranscribeProxyStream({
      languageCode: this._languageCode,
      sampleRate: TRANSCRIBE_SAMPLE_RATE,
    });
    const pump = this._pumpProxy(stream);
    try {
      await stream.ready;
    } catch (e) {
      stream.close();
      await pump;
      throw e;
    }
    return { stream, pump };
  }

  /** Same retry policy as the direct path. Returns null (after reporting) when every attempt fails. */
  async _connectProxy() {
    for (let attempt = 1; attempt <= MAX_START_ATTEMPTS; attempt++) {
      try {
        const session = await this._openProxySession();
        if (this._stopped) {
          session.stream.close();
          return null;
        }
        return session;
      } catch (e) {
        if (this._stopped) return null;
        if (attempt === MAX_START_ATTEMPTS) {
          console.error(
            `${LOGGER_PREFIX} - TranscribeStreamAdapter failed to start via proxy after ` +
            `${MAX_START_ATTEMPTS} attempts — drift baseline unavailable`,
            e
          );
          this._onError(e);
          return null;
        }
        const backoffMs = attempt * 1000;
        console.warn(
          `${LOGGER_PREFIX} - TranscribeStreamAdapter proxy start attempt ${attempt}/${MAX_START_ATTEMPTS} ` +
          `failed, retrying in ${backoffMs}ms`,
          e
        );
        await new Promise((r) => setTimeout(r, backoffMs));
      }
    }
    return null;
  }

  async _runProxy(session) {
    let reconnects = 0;
    while (session && !this._stopped) {
      const streamStartedAt = Date.now();
      const outcome = await session.pump;
      if (outcome === "audioEnded" || this._stopped) return;

      if (Date.now() - streamStartedAt >= PROXY_STABLE_STREAM_MS) reconnects = 0;
      if (++reconnects > MAX_PROXY_RECONNECTS) {
        throw new Error(`Transcribe proxy stream closed ${MAX_PROXY_RECONNECTS} times in a row (${outcome})`);
      }
      console.warn(`${LOGGER_PREFIX} - TranscribeStreamAdapter proxy stream ended (${outcome}) — reconnecting`);
      session = await this._connectProxy();
    }
  }

  /** Feeds audio into one proxy stream until the audio ends or the stream closes. */
  async _pumpProxy(stream) {
    const streamDone = (async () => {
      for await (const { control } of stream.messages()) {
        if (control?.type === "transcript") this._onTranscript(control.text);
        else if (control?.type === "error") return `error: ${control.code}`;
      }
      return `closed: ${stream.closeInfo?.code}`;
    })().then((reason) => ({ streamClosed: reason }));

    for (;;) {
      const next = await Promise.race([this._audioIterator.next(), streamDone]);
      if (next.streamClosed) return next.streamClosed;
      if (next.done) {
        // Let Transcribe finish the last utterance before the stream closes.
        stream.end();
        await streamDone;
        return "audioEnded";
      }
      stream.sendBinary(next.value.AudioEvent.AudioChunk);
    }
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  /**
   * Async generator that yields AudioEvent objects for Transcribe.
   * Pulls Float32 chunks from the worklet queue, encodes to PCM16 @ 16kHz,
   * and wraps in the { AudioEvent: { AudioChunk } } envelope.
   */
  async* _audioGenerator() {
    const inputSampleRate = this._audioContext.sampleRate;
    // Low-pass filters before converting to 16 kHz and keeps its state between chunks, so sound above
    // 8 kHz no longer folds into the speech band (see createPcm16Downsampler).
    const downsampler = createPcm16Downsampler(inputSampleRate, TRANSCRIBE_SAMPLE_RATE);

    while (!this._stopped) {
      // Wait for the next chunk from the worklet
      let chunk;
      if (this._chunkQueue.length > 0) {
        chunk = this._chunkQueue.shift();
      } else {
        const result = await new Promise((resolve) => {
          this._chunkResolve = resolve;
        });
        if (result?.done || this._stopped) break;
        chunk = result?.value;
      }

      if (!chunk) break;

      // Encode: Float32 → low-pass + resample to 16kHz → PCM16 little-endian
      const pcm16 = downsampler.process(chunk);

      yield {
        AudioEvent: {
          AudioChunk: pcm16,
        },
      };
    }
  }

  /**
   * Consumes the TranscriptResultStream from Transcribe.
   * Only fires onTranscript for final (non-partial) results.
   */
  async _processResponseStream(transcriptResultStream) {
    try {
      for await (const event of transcriptResultStream) {
        if (this._stopped) break;

        if (event.TranscriptEvent) {
          const results = event.TranscriptEvent.Transcript?.Results ?? [];
          for (const result of results) {
            // Skip partial results — only emit final transcripts
            if (result.IsPartial) continue;

            const transcript = result.Alternatives?.[0]?.Transcript ?? "";
            if (transcript.trim()) {
              console.info(`${LOGGER_PREFIX} - TranscribeStreamAdapter final transcript: "${transcript}"`);
              this._onTranscript(transcript);
            }
          }
        }
      }
    } catch (e) {
      if (!this._stopped) {
        console.error(`${LOGGER_PREFIX} - TranscribeStreamAdapter response stream error`, e);
        this._onError(e);
      }
    }
  }
}