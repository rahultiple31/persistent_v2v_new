// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0

/**
 * turnAccumulator.js
 * ──────────────────
 * Assembles one conversational turn out of the fragments the speech services
 * actually deliver, and commits the assembled pair to the transcript panel.
 *
 * WHY THIS EXISTS
 * ───────────────
 * Neither speech source hands us a whole utterance in one callback:
 *
 *   • Nova Sonic splits its ASR of one utterance across several `textOutput`
 *     events. A real example from the logs:
 *         onUserText("hola varios empleados reportaron correos sospechosos")
 *         onUserText("hoy")
 *     while the matching translation arrived whole:
 *         onAssistantText("Hello, several employees reported suspicious emails today.")
 *
 *   • Nova Sonic emits the ASSISTANT text TWICE per turn — once for the
 *     SPECULATIVE content block and once for FINAL — usually byte-identical.
 *
 *   • Amazon Transcribe emits one callback per FINAL result, and a long agent
 *     sentence can close as several finals. It also emits short spurious
 *     finals ("S", "The", "that") from echo and room noise.
 *
 * The UI used to do `box.textContent = chunk` on every callback, so the box
 * ended a turn showing only the LAST fragment — "hoy" beside a full-sentence
 * translation. The transcript panel then scraped those same boxes with a
 * MutationObserver, so the truncated text went straight into the history.
 *
 * WHAT THIS DOES
 * ──────────────
 * Buffers fragments per channel, merges them with overlap detection (so a
 * repeat collapses and a continuation concatenates), renders the merged text,
 * and commits ONE transcript bubble per turn holding exactly the original and
 * the translation that belong together.
 *
 * TURN BOUNDARIES
 * ───────────────
 * Nova Sonic's `completionEnd` does not arrive in this deployment (it is
 * absent from every captured log), so `onTurnComplete` cannot be relied on as
 * the turn boundary. Two triggers are used instead, and `commit()` stays
 * idempotent so a `completionEnd` that does arrive simply commits early:
 *
 *   1. A new original fragment arriving after a translation exists — the other
 *      side has answered, so the previous pair is closed.
 *   2. A settle timer. Once BOTH sides hold text, SETTLE_MS of quiet commits
 *      the pair. While only one side has text the timer waits ORPHAN_MS before
 *      committing a half-pair, so a slow translation is not torn off its
 *      original into two separate bubbles.
 */

/**
 * Shortest suffix/prefix overlap accepted when joining two fragments.
 * Below this, a chance collision ("...hoy" + "y...") is likelier than a real
 * overlap, so the fragments are concatenated with a space instead.
 */
const MIN_OVERLAP_CHARS = 8;

/** Quiet period that closes a turn once both sides have text. */
const SETTLE_MS = 1500;

/** Longer grace period when only one side has text, waiting for the other. */
const ORPHAN_MS = 6000;

/**
 * How long after committing a turn a repeated translation is still understood
 * as the late half of THAT turn rather than the opening of a new one.
 *
 * Nova Sonic emits its translation twice per turn, once per generation stage.
 * The two are usually byte-identical but they are NOT adjacent: the second
 * lands only once generation for the utterance finishes, seconds after the
 * first. That is longer than SETTLE_MS, so the turn has already been committed
 * by the time the second copy arrives. Without this window the stray copy
 * became a turn of its own, which is what produced a translation-only bubble
 * after every exchange — and worse, if the next speaker's original arrived
 * before that stray committed, the stray was adopted as that turn's
 * translation and the next bubble showed the previous turn's text prepended to
 * its own.
 */
const LATE_DUPLICATE_MS = 12000;

/**
 * Shortest committed fragment that may be used to reject a later one for
 * containing it. Nova Sonic sometimes finishes a multi-sentence turn by
 * re-emitting the WHOLE translation after already sending each sentence
 * separately: "<A>", then "<B>", then "<A> <B>". The recombined copy is new
 * text by every other measure, so only containment catches it.
 *
 * The floor stops a genuinely short utterance being swallowed — a customer who
 * says "Si." and then "Si, correcto." must still get two bubbles.
 */
const MIN_RECOMBINATION_CHARS = 15;

/** How many recent commits to keep for the checks above. */
const RECENT_COMMIT_MEMORY = 4;

/**
 * Merge an incoming fragment into the text accumulated so far.
 *
 * Handles the three shapes the speech services produce:
 *   repeat      — "abc"     + "abc"        → "abc"
 *   growth      — "abc"     + "abcdef"     → "abcdef"
 *   continuation— "abc def" + "def ghi"    → "abc def ghi"   (overlap join)
 *               — "abc"     + "def"        → "abc def"       (plain join)
 *
 * @param {string} existing  text accumulated so far
 * @param {string} incoming  the new fragment
 * @returns {string} merged text
 */
export function mergeTextChunk(existing, incoming) {
  const a = (existing || "").trim();
  const b = (incoming || "").trim();
  if (!b) return a;
  if (!a) return b;

  const la = a.toLowerCase();
  const lb = b.toLowerCase();

  // Identical repeat — Nova Sonic's SPECULATIVE and FINAL assistant blocks.
  if (la === lb) return a;
  // The fragment is already contained at the start of what we have.
  if (la.startsWith(lb)) return a;
  // The fragment is a longer rewrite of what we have — take it whole.
  if (lb.startsWith(la)) return b;

  // Longest suffix of `a` that is also a prefix of `b`, joined without
  // duplicating the shared span.
  const max = Math.min(la.length, lb.length);
  for (let n = max; n >= MIN_OVERLAP_CHARS; n--) {
    if (la.slice(la.length - n) === lb.slice(0, n)) {
      return (a + b.slice(n)).trim();
    }
  }

  return `${a} ${b}`;
}

/**
 * Accumulates and commits one side of the conversation.
 *
 * Element ids rather than element references, resolved on first use, so an
 * instance can be constructed at module scope before the DOM is bound.
 */
export class TurnAccumulator {
  /**
   * @param {object}   opts
   * @param {string}   opts.label         for log lines, e.g. "CUSTOMER"
   * @param {string}   opts.originalId    id of the original-speech div
   * @param {string}   opts.translatedId  id of the translated-speech div
   * @param {function} opts.onCommit      (original, translated) => void
   * @param {number}  [opts.settleMs]
   * @param {number}  [opts.orphanMs]
   */
  constructor({ label, originalId, translatedId, onCommit, settleMs, orphanMs }) {
    this.label = label;
    this.originalId = originalId;
    this.translatedId = translatedId;
    this.onCommit = typeof onCommit === "function" ? onCommit : () => {};
    this.settleMs = settleMs ?? SETTLE_MS;
    this.orphanMs = orphanMs ?? ORPHAN_MS;

    this.original = "";
    this.translated = "";
    this._timer = null;

    // The last few translations put on screen, so a repeat OR a recombination
    // of them can be recognised rather than treated as new content.
    // [{ text, at }], newest last, capped at RECENT_COMMIT_MEMORY.
    this._recentCommits = [];

    // The boxes keep showing the previous turn until the new turn produces
    // text for that side, so there is no blank gap mid-conversation.
    this._clearOriginalOnNextRender = false;
    this._clearTranslatedOnNextRender = false;

    this._originalEl = null;
    this._translatedEl = null;
  }

  // ── fragment intake ──────────────────────────────────────────────────────

  /**
   * Add a fragment of the ORIGINAL (spoken) text.
   *
   * An original arriving once the current turn is COMPLETE — both an original
   * and its translation are held — means the turn has been answered and this
   * fragment begins the next one, so the finished pair is committed first.
   *
   * The completeness test matters. A translation can land before its own
   * original: on the agent channel the original comes from Transcribe and the
   * translation from Nova Sonic, two independently endpointed streams, and a
   * short utterance can have Nova answer before Transcribe closes its FINAL.
   * Committing on "a translation exists" alone would emit that translation as
   * a bubble with no original, then strand the original in the next turn —
   * splitting one exchange across two mismatched bubbles.
   */
  pushOriginal(chunk) {
    if (!chunk || !chunk.trim()) return;
    if (this.original && this.translated) this.commit();
    this.original = mergeTextChunk(this.original, chunk);
    this._renderOriginal();
    this._schedule();
  }

  /**
   * Add a fragment of the TRANSLATED text.
   *
   * On an otherwise empty turn, a fragment that merely repeats the translation
   * just committed is Nova Sonic's second generation stage arriving after the
   * settle timer already closed that turn — it is already on screen, so it is
   * dropped rather than opening a turn of its own.
   */
  pushTranslation(chunk) {
    if (!chunk || !chunk.trim()) return;
    if (!this.original && !this.translated && this._isLateDuplicate(chunk)) {
      return;
    }
    this.translated = mergeTextChunk(this.translated, chunk);
    this._renderTranslated();
    this._schedule();
  }

  /**
   * Replace the original outright rather than merging into it.
   * @param {string}  text
   * @param {boolean} [render=true]  false leaves the box alone (typed input,
   *                                 which has its own input field on screen)
   */
  setOriginal(text, render = true) {
    this.original = (text || "").trim();
    if (render) this._renderOriginal();
    this._schedule();
  }

  /**
   * Replace the translation outright. Used by the Translate+Polly fallback,
   * which supersedes the Nova Sonic output for the turn rather than adding
   * to it.
   */
  setTranslation(text) {
    this.translated = (text || "").trim();
    this._renderTranslated();
    this._schedule();
  }

  /**
   * Drop the original for this turn — the adapter's Layer 5 retraction
   * determined it was a role misfire, not the speaker's words.
   */
  clearOriginal() {
    this.original = "";
    const el = this._resolveOriginal();
    if (el) el.textContent = "";
  }

  // ── commit / reset ───────────────────────────────────────────────────────

  /**
   * Commit the assembled pair as one transcript bubble and start a new turn.
   * Idempotent: with both buffers empty it does nothing, so an extra call from
   * `onTurnComplete` after the settle timer has already fired is harmless.
   */
  commit() {
    this._cancelTimer();
    const original = this.original.trim();
    const translated = this.translated.trim();
    if (!original && !translated) return;

    this.original = "";
    this.translated = "";
    this._clearOriginalOnNextRender = true;
    this._clearTranslatedOnNextRender = true;
    if (translated) {
      this._recentCommits.push({ text: translated, at: Date.now() });
      if (this._recentCommits.length > RECENT_COMMIT_MEMORY) {
        this._recentCommits.shift();
      }
    }

    try {
      this.onCommit(original, translated);
    } catch (e) {
      console.error(`[TurnAccumulator:${this.label}] onCommit failed`, e);
    }
  }

  /** Discard the in-flight turn and blank both boxes. Used on teardown. */
  reset() {
    this._cancelTimer();
    this.original = "";
    this.translated = "";
    this._clearOriginalOnNextRender = false;
    this._clearTranslatedOnNextRender = false;
    const origEl = this._resolveOriginal();
    if (origEl) origEl.textContent = "";
    const transEl = this._resolveTranslated();
    if (transEl) transEl.textContent = "";
  }

  // ── private ──────────────────────────────────────────────────────────────

  /**
   * True when `chunk` adds nothing to the translation just committed.
   *
   * mergeTextChunk falls back to a plain space-join only when it finds no
   * repetition, containment or overlap between the two. So "the merge is not a
   * plain join" is exactly "this fragment is text we already have", which
   * catches an identical copy, a truncated one and an extended one alike.
   *
   * Gated on the turn being empty, so once the next speaker's original has
   * arrived this never fires and a genuine translation can never be dropped.
   */
  _isLateDuplicate(chunk) {
    const now = Date.now();
    const incoming = chunk.trim();
    const incomingLower = incoming.toLowerCase();

    for (const { text: committed, at } of this._recentCommits) {
      if (now - at > LATE_DUPLICATE_MS) continue;

      // (a) Adds nothing to a translation already on screen. mergeTextChunk
      //     falls back to a plain space-join only when it finds no repetition,
      //     containment or overlap — so "the merge is not a plain join" is
      //     exactly "we already have this text". Catches the second generation
      //     stage, whether identical, truncated or extended.
      if (mergeTextChunk(committed, incoming) !== `${committed} ${incoming}`) {
        return true;
      }

      // (b) Recombination: the model re-sent an earlier sentence glued to a
      //     later one. Only containment identifies this, because the joined
      //     string shares no prefix or suffix with either piece.
      if (
        committed.length >= MIN_RECOMBINATION_CHARS &&
        incomingLower.includes(committed.toLowerCase())
      ) {
        return true;
      }
    }
    return false;
  }

  _resolveOriginal() {
    if (!this._originalEl && this.originalId) {
      this._originalEl = document.getElementById(this.originalId);
    }
    return this._originalEl;
  }

  _resolveTranslated() {
    if (!this._translatedEl && this.translatedId) {
      this._translatedEl = document.getElementById(this.translatedId);
    }
    return this._translatedEl;
  }

  _renderOriginal() {
    this._clearOriginalOnNextRender = false;
    const el = this._resolveOriginal();
    if (el) el.textContent = this.original;
  }

  _renderTranslated() {
    this._clearTranslatedOnNextRender = false;
    const el = this._resolveTranslated();
    if (el) el.textContent = this.translated;
  }

  _cancelTimer() {
    if (this._timer) {
      clearTimeout(this._timer);
      this._timer = null;
    }
  }

  /**
   * (Re)arm the settle timer. A complete pair closes quickly; a half-pair is
   * given much longer, because committing it early would split one turn across
   * two bubbles — the exact mismatch this module exists to prevent.
   */
  _schedule() {
    this._cancelTimer();
    const complete = Boolean(this.original && this.translated);
    this._timer = setTimeout(
      () => {
        this._timer = null;
        this.commit();
      },
      complete ? this.settleMs : this.orphanMs,
    );
  }
}
