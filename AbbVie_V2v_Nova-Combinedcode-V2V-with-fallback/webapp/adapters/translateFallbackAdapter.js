// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
//
// Guaranteed-output translation path.
//
// WHY THIS EXISTS
//   Nova Sonic is the primary interpreter, but it can fail in two ways that
//   both end with the customer not hearing a translation:
//
//     DRIFT   — it echoes the agent's source language instead of translating.
//     REFUSAL — its safety alignment treats the utterance as a sensitive-data
//               request ("share your employee ID and password") and it answers
//               as an assistant ("Lo siento, pero no puedo…") instead of
//               translating. A system prompt cannot override a guardrail.
//
//   Detecting those and muting the audio leaves the customer in silence and
//   loses the agent's sentence. Instead we mute Nova Sonic and synthesise the
//   correct translation here: Amazon Translate + Amazon Polly. Both are
//   deterministic and carry no conversational guardrails, so this path cannot
//   itself refuse — it always produces speech.
//
//   The latency cost lands only on the failure path; the happy path still runs
//   entirely through Nova Sonic.
import { LOGGER_PREFIX, POLLY_FALLBACK_VOICE_MAP, POLLY_NEAREST_NEIGHBOUR_MAP } from "../constants";
import { PROXY_CONFIG } from "../config";
import { getValidAwsCredentials, hasValidAwsCredentials } from "../utils/authUtility";
import { requestProxyFallback } from "../utils/proxyTransport";

let _translateClient;
let _pollyClient;
let _translateRegion;
let _pollyRegion;
let _sdk;

/**
 * Direct mode only. Both clients are rebuilt whenever the Cognito credentials go
 * stale, mirroring getBedrockRuntimeClient() in novaSonicAdapter.js. The SDK
 * modules are imported on first use so the proxy build never loads them.
 */
async function getClients(translateRegion, pollyRegion) {
  if (
    _translateClient &&
    _pollyClient &&
    _translateRegion === translateRegion &&
    _pollyRegion === pollyRegion &&
    hasValidAwsCredentials()
  ) {
    return { translate: _translateClient, polly: _pollyClient, sdk: _sdk };
  }
  const [c, translateSdk, pollySdk] = await Promise.all([
    getValidAwsCredentials(),
    import("@aws-sdk/client-translate"),
    import("@aws-sdk/client-polly"),
  ]);
  _sdk = { TranslateTextCommand: translateSdk.TranslateTextCommand, SynthesizeSpeechCommand: pollySdk.SynthesizeSpeechCommand };
  const credentials = {
    accessKeyId: c.accessKeyId,
    secretAccessKey: c.secretAccessKey,
    sessionToken: c.sessionToken,
  };
  _translateClient = new translateSdk.TranslateClient({ region: translateRegion, credentials });
  _pollyClient = new pollySdk.PollyClient({ region: pollyRegion, credentials });
  _translateRegion = translateRegion;
  _pollyRegion = pollyRegion;
  return { translate: _translateClient, polly: _pollyClient, sdk: _sdk };
}

// fix 4: set after the first failed generative request (the region may not offer generative voices),
// so later requests go straight to the neural voice instead of failing first every time.
let generativeUnavailable = false;

/**
 * The neural voice standing in for a generative one. fix 7: some generative voices (Tiffany, Ambre,
 * Beatrice) have no neural version, so their map entry names another voice for neural (`neuralVoiceId`).
 */
function neuralVersionOf(voice) {
  return { voiceId: voice.neuralVoiceId || voice.voiceId, engine: "neural" };
}

/** The voice to request now: a generative voice becomes neural once generative has failed. */
function usableVoice(voice) {
  if (voice && voice.engine === "generative" && generativeUnavailable) return neuralVersionOf(voice);
  return voice;
}

/** Called when Polly failed for `voice`. Returns the neural voice to retry with, or null. */
function neuralRetryFor(voice) {
  if (!voice || voice.engine !== "generative") return null;
  generativeUnavailable = true;
  const neural = neuralVersionOf(voice);
  console.warn(
    `${LOGGER_PREFIX} - [FALLBACK] Polly generative voice ${voice.voiceId} failed — using the neural voice` +
    ` (${neural.voiceId}) from now on`
  );
  return neural;
}

/**
 * Proxy mode: Translate and Polly run on the proxy with the same failure
 * semantics — null when translation fails, text without audio when only
 * synthesis fails. Logs carry language codes and the voice, never the text.
 */
async function synthesizeViaProxy({ text, sourceLangCode, targetLangCode, voice, voiceLabel, quiet }) {
  let result;
  voice = usableVoice(voice);
  try {
    result = await requestProxyFallback({ text, sourceLanguageCode: sourceLangCode, targetLanguageCode: targetLangCode, voice });
    const retryVoice = result.audioError ? neuralRetryFor(voice) : null;
    if (retryVoice) {
      voice = retryVoice;
      result = await requestProxyFallback({ text, sourceLanguageCode: sourceLangCode, targetLanguageCode: targetLangCode, voice });
    }
  } catch (e) {
    console.error(`${LOGGER_PREFIX} - [FALLBACK] translation via proxy failed`, e);
    return null;
  }
  const translatedText = (result.translatedText || "").trim();
  if (!translatedText) {
    console.error(`${LOGGER_PREFIX} - [FALLBACK] Amazon Translate returned empty text`);
    return null;
  }
  // The voice actually used (fix 7: the neural stand-in can be a different voice).
  if (voice) voiceLabel = voiceLabel.replace(/^\w+\/[\w-]+/, `${voice.voiceId}/${voice.engine}`);
  if (result.audioError) {
    console.error(`${LOGGER_PREFIX} - [FALLBACK] Amazon Polly failed (voice: ${voiceLabel}) — returning text only`);
  } else if (!quiet) {
    console.info(
      `${LOGGER_PREFIX} - [FALLBACK] ${voice ? `synthesised via ${voiceLabel}` : "translate-only (no Polly voice)"}` +
      ` ${sourceLangCode}→${targetLangCode} via proxy`
    );
  }
  return { audio: result.audio, text: translatedText, voiceLabel };
}

/** Direct mode: SynthesizeSpeech, retried once with the neural voice if the generative one fails. */
async function pollySpeak(polly, SynthesizeSpeechCommand, text, voice) {
  voice = usableVoice(voice);
  const speak = async (v) => {
    const speech = await polly.send(
      new SynthesizeSpeechCommand({ Text: text, OutputFormat: "mp3", VoiceId: v.voiceId, Engine: v.engine })
    );
    return speech.AudioStream.transformToByteArray();
  };
  try {
    return { audio: await speak(voice), voice };
  } catch (e) {
    const retryVoice = neuralRetryFor(voice);
    if (!retryVoice) throw e;
    return { audio: await speak(retryVoice), voice: retryVoice };
  }
}

/** Native Polly voice for the language, else the nearest neighbour (with a warning), else null. */
function resolvePollyVoice(targetLangCode) {
  const native = POLLY_FALLBACK_VOICE_MAP[targetLangCode];
  if (native) return { voice: native, usingNearestNeighbour: false };
  const neighbour = POLLY_NEAREST_NEIGHBOUR_MAP[targetLangCode];
  if (!neighbour) return { voice: null, usingNearestNeighbour: false };
  console.warn(
    `${LOGGER_PREFIX} - [FALLBACK] ${neighbour.reason}` +
    ` | target: "${targetLangCode}" | voice: ${neighbour.voiceId}/${neighbour.engine}`
  );
  return { voice: { voiceId: neighbour.voiceId, engine: neighbour.engine }, usingNearestNeighbour: true };
}

/**
 * Speak text that is already in the target language (fix 4): what Nova Sonic heard when it heard the
 * agent in the customer's language. No Translate step. Returns null when it cannot be spoken (no
 * voice, Polly failed, or a proxy that does not yet support speaking without translating), so the
 * caller can fall back to translating the agent's own words.
 *
 * @returns {Promise<{ audio: Uint8Array, text: string, voiceLabel: string } | null>}
 */
export async function synthesizeTargetSpeech({ text, targetLangCode, translateRegion, pollyRegion }) {
  const t = (text || "").trim();
  if (!t) return null;
  const { voice } = resolvePollyVoice(targetLangCode);
  if (!voice) return null;

  if (PROXY_CONFIG.enabled) {
    const result = await synthesizeViaProxy({
      text: t,
      sourceLangCode: targetLangCode,
      targetLangCode,
      voice,
      voiceLabel: `${voice.voiceId}/${voice.engine}`,
      quiet: true,
    });
    return result && result.audio ? result : null;
  }

  try {
    const { polly, sdk } = await getClients(translateRegion, pollyRegion);
    const spoken = await pollySpeak(polly, sdk.SynthesizeSpeechCommand, t, voice);
    return { audio: spoken.audio, text: t, voiceLabel: `${spoken.voice.voiceId}/${spoken.voice.engine}` };
  } catch (e) {
    console.error(`${LOGGER_PREFIX} - [FALLBACK] Amazon Polly failed (voice: ${voice.voiceId})`, e);
    return null;
  }
}

export function invalidateFallbackClients() {
  _translateClient = null;
  _pollyClient = null;
  _translateRegion = null;
  _pollyRegion = null;
}

/**
 * Amazon Translate rejects a source and target that are the same language.
 * When the agent and customer share a language there is nothing to translate,
 * so the caller should never have reached the fallback — guard anyway.
 */
function isSameLanguage(a, b) {
  if (!a || !b) return false;
  return a.toLowerCase() === b.toLowerCase();
}

/**
 * Translate `sourceText` and synthesise it as speech.
 *
 * @param {Object} opts
 * @param {string} opts.sourceText     - What the agent actually said (source language)
 * @param {string} opts.sourceLangCode - Interpreter language code, e.g. "en"
 * @param {string} opts.targetLangCode - Interpreter language code, e.g. "es"
 * @param {string} opts.translateRegion - AWS region for Amazon Translate
 * @param {string} opts.pollyRegion     - AWS region for Amazon Polly
 * @param {boolean} [opts.quiet]        - Skip the success log line (used when prefetching a translation
 *                                        that may never be played)
 * @returns {Promise<{ audio: Uint8Array, text: string } | null>}
 *          MP3 bytes ready for AudioStreamManager.playAudioBuffer(), plus the
 *          translated text for the UI. Returns null when no translation could
 *          be produced (caller then leaves Nova Sonic's audio alone rather than
 *          delivering silence).
 */
export async function synthesizeFallbackTranslation({
  sourceText,
  sourceLangCode,
  targetLangCode,
  translateRegion,
  pollyRegion,
  quiet = false,
}) {
  const text = (sourceText || "").trim();
  if (!text) {
    console.warn(`${LOGGER_PREFIX} - [FALLBACK] no source text available — cannot synthesise`);
    return null;
  }
  if (isSameLanguage(sourceLangCode, targetLangCode)) {
    console.warn(
      `${LOGGER_PREFIX} - [FALLBACK] source and target are both "${targetLangCode}" — nothing to translate`
    );
    return null;
  }

  // GAP 5 FIX: Two-tier voice resolution.
  //
  // Tier 1 — exact match in POLLY_FALLBACK_VOICE_MAP (native Polly voice for
  //           the target language). This is always preferred.
  // Tier 2 — nearest-neighbour from POLLY_NEAREST_NEIGHBOUR_MAP for languages
  //           that have no native Polly voice (currently: id, uk). The
  //           translated TEXT from Amazon Translate is still perfectly correct;
  //           only the TTS voice is approximate. A warning is logged every
  //           time so the team knows which calls are using a fallback voice.
  // Tier 3 — no voice found at all: return { audio: null, text } so the
  //           translated text still reaches the UI transcript and the agent
  //           can read it, rather than returning null (which leaves both the
  //           transcript and the audio empty — worse than partial output).
  const { voice, usingNearestNeighbour } = resolvePollyVoice(targetLangCode);

  // ── Tier 3 guard ─────────────────────────────────────────────────────────
  // If voice is still null here no native or nearest-neighbour Polly voice
  // exists for this language. We still run the Translate step so the agent
  // sees the translated text in the UI transcript, but we skip Polly synthesis
  // and return audio:null. The caller must guard on result.audio before
  // attempting playback. Returning null entirely would lose the transcript
  // entry, which is worse than silent-but-readable.
  const skipAudio = !voice;
  if (skipAudio) {
    console.error(
      `${LOGGER_PREFIX} - [FALLBACK] no Polly voice (native or nearest-neighbour)` +
      ` for target language "${targetLangCode}" — will translate text only, no audio`
    );
  }

  if (PROXY_CONFIG.enabled) {
    return synthesizeViaProxy({
      text,
      sourceLangCode,
      targetLangCode,
      voice: skipAudio ? null : voice,
      voiceLabel: voice ? `${voice.voiceId}/${voice.engine}${usingNearestNeighbour ? " [nearest-neighbour]" : ""}` : "none",
      quiet,
    });
  }

  const { translate, polly, sdk } = await getClients(translateRegion, pollyRegion);
  const { TranslateTextCommand, SynthesizeSpeechCommand } = sdk;

  // ── 1. Translate ──────────────────────────────────────────────────────────
  let translatedText;
  try {
    const result = await translate.send(
      new TranslateTextCommand({
        Text: text,
        SourceLanguageCode: sourceLangCode,
        TargetLanguageCode: targetLangCode,
      })
    );
    translatedText = (result?.TranslatedText || "").trim();
  } catch (e) {
    console.error(`${LOGGER_PREFIX} - [FALLBACK] Amazon Translate failed`, e);
    return null;
  }

  if (!translatedText) {
    console.error(`${LOGGER_PREFIX} - [FALLBACK] Amazon Translate returned empty text`);
    return null;
  }

  // ── 2. Synthesise ─────────────────────────────────────────────────────────
  // Skipped when skipAudio=true (Tier 3 path: no native or nearest-neighbour
  // Polly voice). We still return the translated text so the UI transcript is
  // updated. The caller must guard on result.audio before attempting playback.
  let audio = null;
  if (!skipAudio) {
    let spokenVoice = voice;
    try {
      const spoken = await pollySpeak(polly, SynthesizeSpeechCommand, translatedText, voice);
      audio = spoken.audio;
      spokenVoice = spoken.voice;
    } catch (e) {
      console.error(
        `${LOGGER_PREFIX} - [FALLBACK] Amazon Polly failed` +
        ` (voice: ${voice.voiceId}, engine: ${voice.engine})`,
        e
      );
      // Polly failed but translation succeeded — return text-only so the
      // transcript is still updated rather than losing the turn entirely.
      return { audio: null, text: translatedText };
    }

    const voiceLabel = usingNearestNeighbour
      ? `${spokenVoice.voiceId}/${spokenVoice.engine} [nearest-neighbour for "${targetLangCode}"]`
      : `${spokenVoice.voiceId}/${spokenVoice.engine}`;
    if (!quiet) {
      console.info(
        `${LOGGER_PREFIX} - [FALLBACK] synthesised ${sourceLangCode}→${targetLangCode}` +
        ` via ${voiceLabel} | "${translatedText.slice(0, 60)}"`
      );
    }
    return { audio, text: translatedText, voiceLabel };
  } else {
    console.info(
      `${LOGGER_PREFIX} - [FALLBACK] translate-only (no Polly voice) ${sourceLangCode}→${targetLangCode}` +
      ` | "${translatedText.slice(0, 60)}"`
    );
  }

  return { audio, text: translatedText };
}