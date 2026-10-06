// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  validateFallbackRequest,
  validateNovaInputEvent,
  validatePcmChunk,
  validateTranscribeStart,
} from "../src/validation.js";
import { loadConfig } from "../src/config.js";

const bytes = (value) => Buffer.from(typeof value === "string" ? value : JSON.stringify(value));

test("Nova input: accepts each allowed event type", () => {
  for (const type of ["sessionStart", "promptStart", "contentStart", "textInput", "audioInput", "contentEnd", "promptEnd", "sessionEnd"]) {
    assert.deepEqual(validateNovaInputEvent(bytes({ event: { [type]: {} } })), { ok: true, value: type });
  }
});

test("Nova input: rejects unknown types, extra keys and malformed JSON", () => {
  assert.equal(validateNovaInputEvent(bytes({ event: { toolResult: {} } })).reason, "eventNotAllowed");
  assert.equal(validateNovaInputEvent(bytes({ event: { audioInput: {}, textInput: {} } })).reason, "eventNotAllowed");
  assert.equal(validateNovaInputEvent(bytes({ event: { audioInput: {} }, extra: 1 })).reason, "invalidEnvelope");
  assert.equal(validateNovaInputEvent(bytes({ event: [] })).reason, "invalidEnvelope");
  assert.equal(validateNovaInputEvent(bytes("{not json")).reason, "invalidJson");
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
  const env = { COGNITO_USER_POOL_ID: "p", COGNITO_CLIENT_ID: "c", BEDROCK_REGION: "us-east-1", NOVA_MODEL_ID: "m" };
  assert.throws(() => loadConfig({}), /Missing required environment variables/);
  assert.throws(() => loadConfig({ ...env, NODE_ENV: "production" }), /ALLOWED_ORIGINS is required/);
  assert.throws(() => loadConfig({ ...env, PORT: "abc" }), /PORT must be a positive integer/);
  const config = loadConfig({ ...env, ALLOWED_ORIGINS: "https://a.example.com/, https://b.example.com", TRANSCRIBE_REGION: "eu-west-1" });
  assert.deepEqual(config.allowedOrigins, ["https://a.example.com", "https://b.example.com"]);
  assert.equal(config.transcribeRegion, "eu-west-1");
  assert.equal(config.translateRegion, "us-east-1");
});
