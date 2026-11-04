// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import { test } from "node:test";
import assert from "node:assert/strict";
import { createPieceSplitter } from "../src/services/transcriptPieces.js";

/**
 * A Transcribe result from "word word, word." notation; the first `stable` items are marked Stable.
 * `confidence` is given to every word, or one score per word (punctuation gets none, as from Transcribe).
 */
function result(text, { stable = Infinity, partial = true, id = "r1", confidence } = {}) {
  const tokens = text.match(/[^\s.,!?。、]+|[.,!?。、]/g) ?? [];
  let word = 0;
  const Items = tokens.map((Content, i) => {
    const punctuation = /^[.,!?。、]$/.test(Content);
    const score = punctuation || confidence == null ? undefined : Array.isArray(confidence) ? confidence[word++] : confidence;
    return {
      Content,
      Type: punctuation ? "punctuation" : "pronunciation",
      ...(partial ? { Stable: i < stable } : {}),
      ...(score == null ? {} : { Confidence: score }),
    };
  });
  return { ResultId: id, IsPartial: partial, Alternatives: [{ Transcript: text, Items }] };
}

const texts = (pieces) => pieces.map((piece) => piece.text);
const textOf = (piece) => piece?.text ?? null;

test("pieces: a stable part up to a comma is sent before the sentence ends, the rest with the final", () => {
  const s = createPieceSplitter("en-US");
  assert.deepEqual(texts(s.partial(result("Thank you for calling", { stable: 2 }))), []);
  assert.deepEqual(texts(s.partial(result("Thank you for calling, how can I", { stable: 5 }))), ["Thank you for calling,"]);
  assert.deepEqual(texts(s.partial(result("Thank you for calling, how can I help", { stable: 7 }))), []);
  assert.equal(textOf(s.final(result("Thank you for calling, how can I help you today?", { partial: false }))), "how can I help you today?");
});

test("pieces: several pieces completed by one partial result are all sent, in order", () => {
  const s = createPieceSplitter("en-US");
  assert.deepEqual(texts(s.partial(result("I checked your account, it looks fine. Anything else"))), [
    "I checked your account,",
    "it looks fine.",
  ]);
  assert.equal(textOf(s.final(result("I checked your account, it looks fine. Anything else?", { partial: false }))), "Anything else?");
});

test("pieces: a piece shorter than three words joins what follows", () => {
  const s = createPieceSplitter("en-US");
  assert.deepEqual(texts(s.partial(result("Yes, of course, I can do that"))), ["Yes, of course,"]);
});

test("pieces: nothing is cut while a word before the punctuation is still unstable", () => {
  const s = createPieceSplitter("en-US");
  assert.deepEqual(s.partial(result("My name is John, and", { stable: 3 })), []);
});

test("pieces: a final already covered by its pieces adds nothing, and the next sentence starts afresh", () => {
  const s = createPieceSplitter("en-US");
  assert.deepEqual(texts(s.partial(result("That is all for today."))), ["That is all for today."]);
  assert.equal(s.final(result("That is all for today.", { partial: false })), null);
  assert.deepEqual(texts(s.partial(result("See you soon, bye now", { id: "r2" }))), ["See you soon,"]);
  assert.equal(textOf(s.final(result("See you soon, bye now.", { partial: false, id: "r2" }))), "bye now.");
});

test("pieces: a final with no earlier pieces is one piece; a result without items gives none", () => {
  const s = createPieceSplitter("en-US");
  assert.equal(textOf(s.final(result("ok thanks", { partial: false }))), "ok thanks");
  assert.equal(s.final({ IsPartial: false, Alternatives: [{ Transcript: "no items" }] }), null);
});

test("pieces: Japanese is joined without spaces and cut at its own punctuation", () => {
  const s = createPieceSplitter("ja-JP");
  assert.deepEqual(texts(s.partial(result("お 電話 ありがとう 、 ご 用件"))), ["お電話ありがとう、"]);
});

test("pieces: Spanish opening marks keep to their word", () => {
  const s = createPieceSplitter("es-US");
  const r = result("hola señor García, cómo está");
  r.Alternatives[0].Items.splice(4, 0, { Content: "¿", Type: "punctuation", Stable: true });
  assert.deepEqual(texts(s.partial(r)), ["hola señor García,"]);
  assert.equal(textOf(s.final({ ...r, IsPartial: false })), "¿cómo está");
});

test("pieces: a short sentence on its own comes with its word count and average confidence", () => {
  const s = createPieceSplitter("en-US");
  // Two words with scores 0.2 and 0.5; the full stop has no score and does not count.
  assert.deepEqual(s.final(result("The end.", { partial: false, confidence: [0.2, 0.5] })), {
    text: "The end.",
    words: 2,
    confidence: 0.35,
    wholeSentence: true,
  });
});

test("pieces: the end of a longer sentence, and a piece cut while it is spoken, are not whole sentences", () => {
  const s = createPieceSplitter("en-US");
  const [first] = s.partial(result("Thank you for calling, how", { confidence: 0.9 }));
  assert.deepEqual(first, { text: "Thank you for calling,", words: 4, confidence: 0.9, wholeSentence: false });
  const last = s.final(result("Thank you for calling, how are you?", { partial: false, confidence: 0.3 }));
  assert.deepEqual(last, { text: "how are you?", words: 3, confidence: 0.3, wholeSentence: false });
});

test("pieces: confidence is null when Transcribe gives no scores", () => {
  const s = createPieceSplitter("en-US");
  assert.equal(s.final(result("ok thanks", { partial: false })).confidence, null);
});
