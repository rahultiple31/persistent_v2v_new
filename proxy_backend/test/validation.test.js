// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  validateFallbackRequest,
  validateNovaInputEvent,
  validateNovaStart,
  validatePcmChunk,
  validateTranscribeStart,
} from "../src/validation.js";
import { loadConfig } from "../src/config.js";

const bytes = (value) => Buffer.from(typeof value === "string" ? value : JSON.stringify(value));

test("Nova input: accepts each allowed event type", () => {
  for (const type of ["sessionStart", "promptStart", "contentStart", "textInput", "audioInput", "contentEnd", "promptEnd", "sessionEnd"]) {
    const frame = { event: { [type]: { promptName: "p" } } };
    assert.deepEqual(validateNovaInputEvent(bytes(frame)), { ok: true, value: { type, body: { promptName: "p" }, frame } });
  }
});

test("Nova input: rejects unknown types, extra keys and malformed JSON", () => {
  assert.equal(validateNovaInputEvent(bytes({ event: { toolResult: {} } })).reason, "eventNotAllowed");
  assert.equal(validateNovaInputEvent(bytes({ event: { audioInput: {}, textInput: {} } })).reason, "eventNotAllowed");
  assert.equal(validateNovaInputEvent(bytes({ event: { audioInput: {} }, extra: 1 })).reason, "invalidEnvelope");
  assert.equal(validateNovaInputEvent(bytes({ event: [] })).reason, "invalidEnvelope");
  assert.equal(validateNovaInputEvent(bytes("{not json")).reason, "invalidJson");
});

test("Nova start: needs the prompt's languages and mode", () => {
  const prompt = { source: "en", target: "es", mode: "speech" };
  assert.deepEqual(validateNovaStart({ prompt }), { ok: true, value: prompt });
  assert.equal(validateNovaStart({ prompt: { ...prompt, mode: "typed", target: "pt-PT" } }).ok, true);
  assert.equal(validateNovaStart({}).reason, "promptRequired");
  assert.equal(validateNovaStart({ prompt: "en->es" }).reason, "promptRequired");
  assert.equal(validateNovaStart({ prompt: { ...prompt, source: "English" } }).reason, "invalidPromptSource");
  assert.equal(validateNovaStart({ prompt: { ...prompt, target: "es}}{{" } }).reason, "invalidPromptTarget");
  assert.equal(validateNovaStart({ prompt: { ...prompt, mode: "chat" } }).reason, "invalidPromptMode");
});

test("Transcribe start: validates language code and sample rate", () => {
  assert.equal(validateTranscribeStart({ languageCode: "en-US", sampleRate: 16000 }).ok, true);
  assert.equal(validateTranscribeStart({ languageCode: "en", sampleRate: 16000 }).reason, "invalidLanguageCode");
  assert.equal(validateTranscribeStart({ languageCode: "en-US; drop", sampleRate: 16000 }).reason, "invalidLanguageCode");
  assert.equal(validateTranscribeStart({ languageCode: "en-US", sampleRate: 44100 }).reason, "invalidSampleRate");
});

test("PCM chunk: whole 16-bit samples within the size cap", () => {
  assert.equal(validatePcmChunk(Buffer.alloc(3200)).ok, true);
  assert.equal(validatePcmChunk(Buffer.alloc(3)).reason, "invalidPcmChunk");
  assert.equal(validatePcmChunk(Buffer.alloc(0)).reason, "invalidPcmChunk");
  assert.equal(validatePcmChunk(Buffer.alloc(64 * 1024 + 2)).reason, "pcmChunkTooLarge");
});

test("Fallback request: validates text, language codes and voice", () => {
  const base = { text: " hello ", sourceLanguageCode: "en", targetLanguageCode: "zh-TW" };
  assert.deepEqual(validateFallbackRequest(base), { ok: true, value: { ...base, text: "hello", voice: null } });
  assert.deepEqual(validateFallbackRequest({ ...base, voiceId: "Lupe", engine: "neural" }).value.voice, { voiceId: "Lupe", engine: "neural" });
  assert.equal(validateFallbackRequest({ ...base, text: "" }).reason, "missingText");
  assert.equal(validateFallbackRequest({ ...base, text: "x".repeat(3001) }).reason, "textTooLong");
  assert.equal(validateFallbackRequest({ ...base, sourceLanguageCode: "english" }).reason, "invalidSourceLanguageCode");
  assert.equal(validateFallbackRequest({ ...base, voiceId: "Lupe", engine: "turbo" }).reason, "invalidEngine");
  assert.equal(validateFallbackRequest({ ...base, voiceId: "../etc" }).reason, "invalidVoiceId");
  assert.equal(validateFallbackRequest([]).reason, "invalidBody");
});

test("Config: requires core settings, and allowed origins in production", () => {
  const env = { BEDROCK_REGION: "us-east-1", NOVA_MODEL_ID: "m" };
  assert.throws(() => loadConfig({}), /Missing required environment variables/);
  assert.throws(() => loadConfig({ ...env, NODE_ENV: "production" }), /ALLOWED_ORIGINS is required/);
  assert.throws(() => loadConfig({ ...env, PORT: "abc" }), /PORT must be a positive integer/);
  const config = loadConfig({ ...env, ALLOWED_ORIGINS: "https://a.example.com/, https://b.example.com", TRANSCRIBE_REGION: "eu-west-1" });
  assert.deepEqual(config.allowedOrigins, ["https://a.example.com", "https://b.example.com"]);
  assert.equal(config.transcribeRegion, "eu-west-1");
  assert.equal(config.translateRegion, "us-east-1");
});
