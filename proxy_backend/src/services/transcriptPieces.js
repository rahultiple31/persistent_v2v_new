// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
//
// Pieces of a sentence for the backup translation (Transcribe + Translate + Polly), sent while the speaker
// is still talking instead of after the sentence has ended.
//
// With partial-results stabilization on, Transcribe marks each word of a partial result Stable once it
// will no longer change. As soon as every word up to a punctuation mark is stable, that part of the
// sentence is a piece. When the final result arrives, whatever was not sent as a piece yet is the last
// piece. Together, the pieces of a sentence cover it exactly once.

// Where a piece may end: sentence ends and commas, with the full-width forms used in Japanese and Chinese.
const PIECE_ENDS = new Set([".", ",", "!", "?", "。", "、", "，", "！", "？"]);
// A piece has at least this many words, so a lone "Yes," or "Hello," joins what follows: a fragment that
// short translates poorly, and the webapp's echo check ignores anything under three words.
export const MIN_PIECE_WORDS = 3;
// Languages written without spaces between words.
const NO_SPACE_LANGUAGES = /^(ja|zh|th)-/i;

const isPunctuation = (item) => item.Type === "punctuation";
const itemsOf = (result) => result?.Alternatives?.[0]?.Items ?? [];

/**
 * The average of Transcribe's 0-1 confidence score for each word, rounded to two places, or null when
 * Transcribe gave no score. Punctuation has no score of its own and is left out.
 */
function averageConfidence(words) {
  const scores = words.map((item) => item.Confidence).filter((score) => Number.isFinite(score));
  if (!scores.length) return null;
  return Math.round((scores.reduce((sum, score) => sum + score, 0) / scores.length) * 100) / 100;
}

/**
 * Splits one Transcribe stream's results into pieces. Feed it every result of the stream, in order.
 *
 * Each piece is { text, words, confidence, wholeSentence }: its word count and average confidence let the
 * webapp leave out the short "sentences" Transcribe makes of background noise, and wholeSentence is true
 * when the piece is a sentence on its own rather than the end of a longer one.
 * @param {string} languageCode  the stream's language, e.g. "en-US"
 */
export function createPieceSplitter(languageCode) {
  const separator = NO_SPACE_LANGUAGES.test(languageCode || "") ? "" : " ";
  let resultId = null;
  let sent = 0; // items of the current result already sent as pieces

  const join = (items) =>
    items
      .map((item) => item.Content ?? "")
      .join(separator)
      .replace(/\s+([.,!?;:])/g, "$1")
      .replace(/([¿¡])\s+/g, "$1")
      .trim();

  const piece = (items, wholeSentence) => {
    const words = items.filter((item) => !isPunctuation(item));
    return { text: join(items), words: words.length, confidence: averageConfidence(words), wholeSentence };
  };

  return {
    /** A partial result: the pieces it completes, possibly none. */
    partial(result) {
      if (result?.ResultId !== resultId) {
        resultId = result?.ResultId;
        sent = 0;
      }
      const items = itemsOf(result);
      const pieces = [];
      let words = 0;
      for (let i = sent; i < items.length; i++) {
        const item = items[i];
        if (item.Stable !== true) break;
        if (!isPunctuation(item)) words++;
        else if (words >= MIN_PIECE_WORDS && PIECE_ENDS.has(item.Content)) {
          // The sentence is still going on, so this is never counted as a whole sentence.
          pieces.push(piece(items.slice(sent, i + 1), false));
          sent = i + 1;
          words = 0;
        }
      }
      return pieces;
    },

    /** A final result: the last piece of its sentence, or null when earlier pieces already covered it. */
    final(result) {
      const from = result?.ResultId === resultId ? sent : 0;
      resultId = null;
      sent = 0;
      const rest = itemsOf(result).slice(from);
      return rest.some((item) => !isPunctuation(item)) ? piece(rest, from === 0) : null;
    },
  };
}
