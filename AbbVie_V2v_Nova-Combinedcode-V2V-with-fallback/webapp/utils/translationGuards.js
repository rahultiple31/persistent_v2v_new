// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
//
// Checks and bookkeeping for the agent -> customer translation path (fix 4), also used for the
// customer -> agent path (fix 7).
//
// Kept free of browser APIs so it can be unit-tested in Node. main.js wires these into the agent's
// and the customer's Nova Sonic session handlers.
//
// Background: AWS states that Nova 2 Sonic "does not support real-time speech-to-speech translation"
// (AI Service Card). It is a conversational model, and now and then it answers or comments instead of
// translating. Those replies are in the target language, so the language check cannot see them; the
// checks here look at what the reply says instead.

/** Strip diacritics so patterns can be written in plain ASCII. */
function foldAccents(text) {
  return String(text || "")
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "");
}

/** Lower-case, accent-free words, punctuation removed. */
export function normalizeForCompare(text) {
  return foldAccents(text)
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s]/gu, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function words(text) {
  const n = normalizeForCompare(text);
  return n ? n.split(" ") : [];
}

// ─── Talk about the translation task ───────────────────────────────────────
//
// What Nova Sonic says when it slips out of the interpreter role, from the 2026-09-28 calls:
//   "Entendido. Estoy listo para traducir simultáneamente la conversación. Por favor, proporciona el
//    texto o la frase en inglés que deseas traducir."
//   "Lo siento, pero no puedo responder a esta solicitud. Estoy aquí para traducir, no para responder…"
//   "Si tienes un texto en inglés que necesites traducir, por favor…"
// An agent almost never talks about translating, so each group below counts only when the agent's own
// words do NOT contain the same kind of phrase. The groups cover the app's languages (patterns match
// accent-folded, lower-case text).
const TASK_TALK_GROUPS = [
  {
    name: "translation words",
    re: /\b(tradu\w*|translat\w*|interprete|interpreter|interpretes|ubersetz\w*|dolmetsch\w*|vertal\w*|tolk\w*)\b/,
  },
  {
    name: "describes itself",
    re: /\b(estoy (aqui|listo|lista|disponible) para|estou (aqui|pronto|pronta) para|soy (un|una|tu|su) (interprete|traductor|traductora|asistente)|i ?(m|am) (here|ready) to|i ?(m|am) (an?|your) (interpreter|translator|assistant)|je suis (la|pret|prete) pour|je suis (un|une|votre|ton) (interprete|traducteur|assistant)|sono (qui|pronto|pronta) per|sono (un|una|il tuo|la tua) (interprete|traduttore|assistente)|ich bin (hier|bereit)|ich bin (ein|eine|ihr|dein) (dolmetscher|ubersetzer|assistent))\b/,
  },
  {
    name: "asks for text",
    re: /\b(proporcion\w*|envia\w*|escrib\w*|provide|send|type|write|fourni\w*|envoy\w*|ecri\w*|fornisc\w*|invia\w*|scriv\w*|schick\w*|schreib\w*|gib|geben)\b[\s\S]{0,40}\b(texto|frase|oracion|text|phrase|sentence|texte|testo|satz)\b/,
  },
  {
    // fix 7: Nova Sonic thinking aloud instead of speaking the translation. From the 2026-09-30 call,
    // where a fresh customer session spoke its reasoning to the agent for every sentence: "Let's break
    // it down…", "The tone seems neutral and patient", "I will say this exactly as it is, following all
    // the rules", "So my response will be…", "The user isn't asking for advice…". Only phrases a caller
    // is very unlikely to say are listed; the rest of that call's reasoning already mentions translating.
    name: "thinks aloud",
    re: /\b(let s break (it|this) down|the tone (here )?(seems|sounds)|following all the rules|so my response (should|will|would|must) be|i (will|should|must) say (this|it) exactly|the user s input|the user (isn t|is not) asking)\b/,
  },
];

function matchTaskTalk(output, baseline, groups) {
  const out = normalizeForCompare(output);
  if (!out) return null;
  const src = normalizeForCompare(baseline);
  for (const group of groups) {
    if (group.re.test(out) && !group.re.test(src)) return group.name;
  }
  return null;
}

/**
 * True when the output talks about translating or asks for text to translate, and the agent's words
 * (baseline) do not. Returns the matching group name, or null.
 */
export function mentionsTranslationTask(output, baseline) {
  return matchTaskTalk(output, baseline, TASK_TALK_GROUPS);
}

// fix 7: the customer side's groups. A caller says "I'm ready to…" or "I'm here to…" in ordinary speech
// (2026-09-30: "está bien, quedo atento para hablar con el técnico" became "Alright, I am ready to speak
// with the technician."), so of "describes itself" only Nova Sonic naming its own role counts there.
const CUSTOMER_TASK_TALK_GROUPS = [
  TASK_TALK_GROUPS[0],
  {
    name: "names its role",
    re: /\b(soy (un|una|tu|su) (interprete|traductor|traductora|asistente)|i ?(m|am) (an?|your) (interpreter|translator|assistant)|je suis (un|une|votre|ton) (interprete|traducteur|assistant)|sono (un|una|il tuo|la tua) (interprete|traduttore|assistente)|ich bin (ein|eine|ihr|dein) (dolmetscher|ubersetzer|assistent)|sou (um|uma|o seu|a sua|seu|sua) (interprete|tradutor|tradutora|assistente))\b/,
  },
  TASK_TALK_GROUPS[2],
  TASK_TALK_GROUPS[3],
];

/** mentionsTranslationTask for the customer -> agent output (fix 7): see CUSTOMER_TASK_TALK_GROUPS. */
export function customerMentionsTranslationTask(output, heard) {
  return matchTaskTalk(output, heard, CUSTOMER_TASK_TALK_GROUPS);
}

/**
 * True when the output is far longer than what the agent said: the shape of an assistant answer
 * rather than a translation. Deliberately loose (a translation can run ~1.3x the source), so it
 * only catches clear cases.
 */
export function isMuchLongerThan(output, baseline) {
  const o = words(output).length;
  const b = words(baseline).length;
  if (b === 0) return false;
  return o > Math.max(3 * b, b + 15);
}

/**
 * True when two outputs are the same sentence (ignoring case, accents and punctuation), used to spot
 * Nova Sonic repeating itself after hearing its own previous output (call 2b: the customer heard
 * "Puedes decirme cuál es tu problema, por favor?" five times).
 */
export function isSameUtterance(a, b) {
  const x = normalizeForCompare(a);
  const y = normalizeForCompare(b);
  if (!x || !y) return false;
  if (x === y) return true;
  const wx = new Set(x.split(" "));
  const wy = new Set(y.split(" "));
  if (wx.size < 3 || wy.size < 3) return false;
  const inter = [...wx].filter((w) => wy.has(w)).length;
  const union = new Set([...wx, ...wy]).size;
  return inter / union >= 0.8;
}

// ─── What Nova Sonic heard ──────────────────────────────────────────────────
//
// Nova Sonic's USER text is its own transcript of the agent. In the 2026-09-28/29 calls it was often
// already in Spanish: the agent's English, translated as it was heard. Every drift (12) and every
// assistant reply (3) came right after such a hearing: Nova Sonic then translated that Spanish back
// into English, or answered it. When it heard English (16 sentences) it never failed. The Spanish it
// heard was a correct translation each time, so it is what the customer is given when Nova Sonic's
// own output fails: spoken as it is, with no Translate step and no wait for Transcribe.

// Words of one language that are not words of the other, accent-folded. Only for English/Spanish;
// other pairs use the caller's stopword score. "has", "me", "no" and "a" are words in both.
const HEARD_MARKERS = {
  en: new Set([
    "the", "you", "your", "is", "are", "was", "were", "have", "can", "could", "would", "will", "please",
    "what", "how", "do", "does", "did", "to", "and", "of", "it", "any", "this", "that", "i", "my", "we",
    "be", "for", "with", "on", "there", "some", "let",
  ]),
  es: new Set([
    "el", "la", "los", "las", "del", "al", "de", "en", "y", "un", "una", "es", "se", "lo", "le", "les",
    "te", "tu", "su", "sus", "mi", "que", "por", "para", "con", "pero", "como", "esta", "este", "esto",
    "eso", "hay", "muy", "ya", "si", "puedes", "puede", "puedo", "algun", "alguna", "alguno", "hecho",
    "estoy", "tengo", "tiene",
  ]),
};
// Characters that only the language writes. Spanish transcripts from Nova Sonic carry them.
const HEARD_LETTERS = { es: /[ñáéíóú¿¡]/i };

/**
 * Which side of the pair a piece of Nova Sonic's hearing is in: "target" (heard already translated),
 * "source" (heard as spoken) or "unknown" (too short or no clear signal).
 * @param {(text: string, lang: string) => number} [scoreFn] stopword/script score for other pairs
 */
export function heardLanguage(text, sourceLang, targetLang, scoreFn) {
  const t = String(text || "").trim();
  if (!t) return "unknown";
  const srcWords = HEARD_MARKERS[sourceLang];
  const tgtWords = HEARD_MARKERS[targetLang];
  let src;
  let tgt;
  if (srcWords && tgtWords) {
    const ws = words(t);
    src = ws.filter((w) => srcWords.has(w)).length + (HEARD_LETTERS[sourceLang]?.test(t) ? 2 : 0);
    tgt = ws.filter((w) => tgtWords.has(w)).length + (HEARD_LETTERS[targetLang]?.test(t) ? 2 : 0);
  } else if (scoreFn) {
    src = scoreFn(t, sourceLang);
    tgt = scoreFn(t, targetLang);
  } else {
    return "unknown";
  }
  return tgt > src ? "target" : src > tgt ? "source" : "unknown";
}

// Long words are compared by their first five letters, so "problema"/"problemas" and
// "encontré"/"encontrado" count as the same word.
const stem = (w) => (w.length > 5 ? w.slice(0, 5) : w);

/** Share of `text`'s words that also occur in `reference` (1 when `text` has no words). */
export function wordsContainedIn(text, reference) {
  const ws = words(text);
  if (!ws.length) return 1;
  const ref = new Set(words(reference).map(stem));
  return ws.filter((w) => ref.has(stem(w))).length / ws.length;
}

/**
 * True when Nova Sonic's output says what it heard. When it heard the agent already in the target
 * language, the right output is that same sentence (prompt rule 10); an output made mostly of other
 * words is an answer or a comment. Outputs under three words are not judged.
 */
export function matchesHeard(output, heard) {
  if (words(output).length < 3) return true;
  return wordsContainedIn(output, heard) >= 0.6;
}

// How close in time the agent-side hearing and the customer-side transcript of the same speech
// arrive when the agent's microphone picks up the customer (speaker, or phone next to the laptop).
// An agent repeating the customer's words back comes much later: after the translation has played
// and the agent has spoken.
const CUSTOMER_ECHO_WINDOW_MS = 4000;

/**
 * True when what Nova Sonic heard from the agent's microphone was the customer's own voice: a piece
 * of at least four words, most of them in what the customer said at the same moment.
 * @param {{ pieces: { text: string, at: number }[] }} record from HeardUtterance.take()
 * @param {{ text: string, at: number }[]} customerSpeech recent customer transcripts
 */
export function heardFromCustomer(record, customerSpeech) {
  if (!record || !customerSpeech?.length) return false;
  return record.pieces.some((p) => {
    if (words(p.text).length < 4) return false;
    const sameMoment = customerSpeech
      .filter((c) => Math.abs(c.at - p.at) <= CUSTOMER_ECHO_WINDOW_MS)
      .map((c) => c.text)
      .join(" ");
    return sameMoment !== "" && wordsContainedIn(p.text, sameMoment) >= 0.7;
  });
}

// A text block with no new hearing before it continues the last sentence heard, if this recent.
// Nova Sonic sends the blocks of one answer within a second or two of each other.
const HEARD_CONTINUATION_MS = 6000;

/**
 * Nova Sonic's hearing of the agent, sentence by sentence. Pieces heard before Nova Sonic starts to
 * answer belong together ("¿hay algún calentamiento o" + "problemas de sonido?"); take() hands them
 * to the sentence Nova Sonic starts, and the next piece begins a new hearing.
 */
export class HeardUtterance {
  constructor(now = () => Date.now()) {
    this._now = now;
    this.pieces = [];
    this.taken = false;
    this.lastTaken = null;
  }

  /** @param {"target"|"source"|"unknown"} lang from heardLanguage() */
  add(text, lang) {
    const t = String(text || "").trim();
    if (!t) return;
    if (this.taken) {
      this.pieces = [];
      this.taken = false;
    }
    this.pieces.push({ text: t, lang, at: this._now() });
  }

  text() {
    return this.pieces.map((p) => p.text).join(" ").trim();
  }

  /** Speakable to the customer as it is: some of it heard in the target language, none in the source. */
  isUsable() {
    return this.pieces.some((p) => p.lang === "target") && !this.pieces.some((p) => p.lang === "source");
  }

  /** What was heard for the sentence Nova Sonic is starting now, or null when nothing new was heard. */
  take() {
    if (this.taken || this.pieces.length === 0) return null;
    this.taken = true;
    const record = {
      text: this.text(),
      usable: this.isUsable(),
      pieces: this.pieces.slice(),
      takenAt: this._now(),
      previous: this.lastTaken ? this.lastTaken.text : "",
      covered: false, // set once the fallback has spoken it
      echo: false,
    };
    this.lastTaken = record;
    return record;
  }

  /** The last sentence heard, while a text block with no new hearing can still belong to it. */
  continuing() {
    const r = this.lastTaken;
    return r && this._now() - r.takenAt < HEARD_CONTINUATION_MS ? r : null;
  }

  /** Nova Sonic finished answering: later text blocks do not continue the last sentence heard. */
  endTurn() {
    this.lastTaken = null;
  }
}

/** Recent transcripts with their arrival time (the customer's words, for heardFromCustomer). */
export class RecentSpeech {
  constructor(now = () => Date.now(), keepMs = 20000) {
    this._now = now;
    this._keepMs = keepMs;
    this.items = [];
    this.lastAt = 0;
  }

  add(text) {
    const t = String(text || "").trim();
    if (!t) return;
    const now = this._now();
    this.items.push({ text: t, at: now });
    this.lastAt = now;
    this.items = this.items.filter((i) => now - i.at <= this._keepMs).slice(-10);
  }

  list() {
    const now = this._now();
    return this.items.filter((i) => now - i.at <= this._keepMs);
  }

  clear() {
    this.items = [];
    this.lastAt = 0;
  }
}

// ─── What the agent said, one utterance at a time ──────────────────────────
//
// Transcribe returns one FINAL result per segment, and a long sentence closes as several segments.
// The old code kept only the LAST segment, so the classifier and the Translate+Polly fallback saw
// only the end of a long sentence. This joins the segments of the utterance Nova Sonic is currently
// translating.
//
// A "turn" opens at the first ASSISTANT text of Nova Sonic's reply (beginTurn) and closes at its FINAL
// text or turn end (endTurn). Segments that arrive while a turn is open belong to the NEXT utterance
// (the agent kept talking) and are carried over when the turn closes.
const SEGMENT_GAP_MS = 4000; // a pause this long starts a new utterance even with no turn open
const STALE_TURN_MS = 10000; // a turn left open this long is closed before a new one opens
const EMPTY_TURN_ABSORB_MS = 3000; // late segments still count for a turn that opened with none

export class SourceUtterance {
  constructor(now = () => Date.now()) {
    this._now = now;
    this.segments = [];
    this.turnSize = null; // number of segments in the open turn, or null when no turn is open
    this.openedAt = 0;
    this.lastAt = 0;
    this.last = ""; // the most recent closed utterance
    this.provisional = ""; // Nova Sonic's own ASR text, used only until Transcribe delivers
    this.version = 0; // bumps on every new segment
    this._waiters = [];
  }

  add(text) {
    const t = String(text || "").trim();
    if (!t) return;
    const now = this._now();
    if (this.turnSize === null && this.segments.length && now - this.lastAt > SEGMENT_GAP_MS) {
      this.last = this.segments.join(" ");
      this.segments = [];
    }
    this.segments.push(t);
    this.lastAt = now;
    this.version++;
    this.provisional = "";
    // A turn that opened before Transcribe had delivered anything takes the late segments.
    if (this.turnSize === 0 && now - this.openedAt < EMPTY_TURN_ABSORB_MS) {
      this.turnSize = this.segments.length;
    }
    const waiters = this._waiters.splice(0);
    waiters.forEach((resolve) => resolve());
  }

  setProvisional(text) {
    const t = String(text || "").trim();
    if (t && this.segments.length === 0) this.provisional = t;
  }

  /** Everything said since the last closed utterance (what a new turn would cover). */
  current() {
    return this.segments.join(" ").trim();
  }

  /** The utterance the open turn is translating; all pending segments when no turn is open. */
  turnText() {
    const segs = this.turnSize === null ? this.segments : this.segments.slice(0, this.turnSize);
    return segs.join(" ").trim();
  }

  /** Segments not claimed by the open turn: what the agent is saying now, not yet being translated. */
  pendingText() {
    const segs = this.turnSize === null ? this.segments : this.segments.slice(this.turnSize);
    return segs.join(" ").trim();
  }

  isTurnOpen() {
    return this.turnSize !== null;
  }

  beginTurn() {
    const now = this._now();
    if (this.turnSize !== null && now - this.openedAt > STALE_TURN_MS) this.endTurn();
    if (this.turnSize === null) {
      this.turnSize = this.segments.length;
      this.openedAt = now;
    }
  }

  endTurn() {
    if (this.turnSize === null) return;
    const said = this.turnText();
    if (said) this.last = said;
    this.segments = this.segments.slice(this.turnSize);
    this.turnSize = null;
    this.provisional = "";
  }

  /**
   * fix 6: forget everything not yet translated. Used when the backup translation takes these words
   * over, so the checks do not judge Nova Sonic's later output against them.
   */
  clear() {
    this.segments = [];
    this.turnSize = null;
    this.provisional = "";
    const waiters = this._waiters.splice(0);
    waiters.forEach((resolve) => resolve());
  }

  /** Resolves when a new segment arrives, or after timeoutMs. */
  waitForSegment(timeoutMs) {
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        const i = this._waiters.indexOf(done);
        if (i >= 0) this._waiters.splice(i, 1);
        resolve();
      }, timeoutMs);
      const done = () => {
        clearTimeout(timer);
        resolve();
      };
      this._waiters.push(done);
    });
  }
}

// ─── Per-call counters ──────────────────────────────────────────────────────

const STAT_LABELS = [
  ["agentSentences", "agent sentences checked"],
  ["novaOk", "Nova OK"],
  ["drift", "drift"],
  ["refusal", "refusal/assistant reply"],
  ["mismatch", "not what Nova heard"],
  ["echo", "echo repeats blocked"],
  ["heardSpoken", "fallback spoke what Nova heard"],
  ["fallbackPlayed", "fallback played"],
  ["fallbackPrefetched", "of which prefetched"],
  ["fallbackFailed", "fallback failed"],
  ["fallbackNoSource", "fallback without source text"],
  ["uncheckedHeld", "unchecked audio chunks held"],
  ["uncheckedDiscarded", "unchecked audio chunks discarded"],
  ["restarts", "context restarts"],
  ["agentInterruptions", "agent interruptions"],
  ["customerInterruptions", "customer interruptions"],
];

// fix 7: the customer -> agent checks, printed as their own [CUSTOMER-CHECK-SUMMARY] line so the
// fix 4 summary line keeps its format.
export const CUSTOMER_CHECK_STAT_LABELS = [
  ["sentences", "customer sentences checked"],
  ["ok", "Nova OK"],
  ["drift", "drift"],
  ["refusal", "refusal"],
  ["assistantReply", "assistant reply / thinking aloud"],
  ["mutedSentences", "further sentences of a failed turn muted"],
  ["fallbackPlayed", "fallback played"],
  ["fallbackAsHeard", "of which spoken as Nova heard it"],
  ["fallbackFailed", "fallback failed"],
  ["fallbackNoSource", "fallback without source text"],
  ["uncheckedDiscarded", "unchecked audio chunks discarded"],
  ["restarts", "context restarts"],
];

export function createCallStats(labels = STAT_LABELS) {
  const counts = {};
  const reset = () => labels.forEach(([key]) => (counts[key] = 0));
  reset();
  return {
    inc(key, n = 1) {
      if (key in counts) counts[key] += n;
    },
    get(key) {
      return counts[key] || 0;
    },
    hasActivity() {
      return Object.values(counts).some((v) => v > 0);
    },
    summary() {
      return labels.map(([key, label]) => `${label}: ${counts[key]}`).join(" | ");
    },
    reset,
  };
}

// ─── fix 7: sentences already judged ────────────────────────────────────────
//
// Nova Sonic sends each sentence twice (SPECULATIVE, then FINAL), and on the customer side the FINAL
// copies of a long answer often arrive after the turn has ended (2026-09-30 call). The second copy gets
// the first copy's verdict, so a sentence kept from the agent stays hidden and a good one is shown.

export class JudgedSentences {
  constructor(max = 24) {
    this.max = max;
    this.items = [];
  }

  add(text, ok) {
    const key = normalizeForCompare(text);
    if (!key) return;
    this.items.push({ key, ok: !!ok });
    if (this.items.length > this.max) this.items.shift();
  }

  /** The latest verdict for this sentence (same words, or nearly), or null when it was not judged. */
  find(text) {
    const key = normalizeForCompare(text);
    if (!key) return null;
    for (let i = this.items.length - 1; i >= 0; i--) {
      if (this.items[i].key === key) return this.items[i];
    }
    for (let i = this.items.length - 1; i >= 0; i--) {
      if (isSameUtterance(this.items[i].key, key)) return this.items[i];
    }
    return null;
  }

  clear() {
    this.items = [];
  }
}
