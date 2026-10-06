// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0

/** Nova Sonic input events the webapp sends. Anything else is rejected. */
export const NOVA_INPUT_EVENTS = new Set([
  "sessionStart",
  "promptStart",
  "contentStart",
  "textInput",
  "audioInput",
  "contentEnd",
  "promptEnd",
  "sessionEnd",
]);

export const TRANSCRIBE_SAMPLE_RATES = new Set([8000, 16000]);
export const MAX_TRANSCRIBE_CHUNK_BYTES = 64 * 1024;
export const MAX_FALLBACK_TEXT_CHARS = 3000; // Polly's per-request limit
export const POLLY_ENGINES = new Set(["standard", "neural", "generative", "long-form"]);

const TRANSCRIBE_LANGUAGE_CODE = /^[a-z]{2,3}-[A-Z]{2}$/;
const TRANSLATE_LANGUAGE_CODE = /^[a-z]{2,3}(-[A-Za-z]{2,4})?$/;
const POLLY_VOICE_ID = /^[A-Za-z]{2,32}$/;

const ok = (value) => ({ ok: true, value });
const fail = (reason) => ({ ok: false, reason });

function isPlainObject(value) {
  return value != null && typeof value === "object" && !Array.isArray(value);
}

/**
 * Checks one Nova Sonic input frame: a JSON object of the form { event: { <allowed type>: {...} } }.
 * The original bytes are forwarded unchanged, so this only inspects the envelope.
 */
export function validateNovaInputEvent(bytes) {
  let parsed;
  try {
    parsed = JSON.parse(bytes.toString("utf8"));
  } catch {
    return fail("invalidJson");
  }
  if (!isPlainObject(parsed) || Object.keys(parsed).length !== 1 || !isPlainObject(parsed.event)) {
    return fail("invalidEnvelope");
  }
  const types = Object.keys(parsed.event);
  if (types.length !== 1 || !NOVA_INPUT_EVENTS.has(types[0])) return fail("eventNotAllowed");
  return ok(types[0]);
}

/** Validates the parameters of a { type: "start", service: "transcribe", ... } message. */
export function validateTranscribeStart(message) {
  const { languageCode, sampleRate } = message;
  if (typeof languageCode !== "string" || !TRANSCRIBE_LANGUAGE_CODE.test(languageCode)) return fail("invalidLanguageCode");
  if (!TRANSCRIBE_SAMPLE_RATES.has(sampleRate)) return fail("invalidSampleRate");
  return ok({ languageCode, sampleRate });
}

/** A PCM16 chunk: whole 16-bit samples, within the size cap. */
export function validatePcmChunk(bytes) {
  if (bytes.length === 0 || bytes.length % 2 !== 0) return fail("invalidPcmChunk");
  if (bytes.length > MAX_TRANSCRIBE_CHUNK_BYTES) return fail("pcmChunkTooLarge");
  return ok(bytes);
}

/** Validates the JSON body of POST /api/fallback. */
export function validateFallbackRequest(body) {
  if (!isPlainObject(body)) return fail("invalidBody");
  const { text, sourceLanguageCode, targetLanguageCode, voiceId, engine } = body;
  if (typeof text !== "string" || !text.trim()) return fail("missingText");
  if (text.length > MAX_FALLBACK_TEXT_CHARS) return fail("textTooLong");
  if (typeof sourceLanguageCode !== "string" || !TRANSLATE_LANGUAGE_CODE.test(sourceLanguageCode)) {
    return fail("invalidSourceLanguageCode");
  }
  if (typeof targetLanguageCode !== "string" || !TRANSLATE_LANGUAGE_CODE.test(targetLanguageCode)) {
    return fail("invalidTargetLanguageCode");
  }
  let voice = null;
  if (voiceId != null) {
    if (typeof voiceId !== "string" || !POLLY_VOICE_ID.test(voiceId)) return fail("invalidVoiceId");
    if (!POLLY_ENGINES.has(engine)) return fail("invalidEngine");
    voice = { voiceId, engine };
  }
  return ok({ text: text.trim(), sourceLanguageCode, targetLanguageCode, voice });
}

/** Parses a text control frame. Returns null for anything that is not { type: string, ... }. */
export function parseControlMessage(bytes) {
  try {
    const message = JSON.parse(bytes.toString("utf8"));
    return isPlainObject(message) && typeof message.type === "string" ? message : null;
  } catch {
    return null;
  }
}
