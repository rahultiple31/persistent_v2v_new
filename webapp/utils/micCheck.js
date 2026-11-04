// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
//
// fix 14 (temporary diagnostic): what the agent's Transcribe receives from the microphone in the first
// minutes after Start. One console line per second ([MIC-CHECK]), one line for every phrase Transcribe
// returns with its confidence, and a summary at the end. It tells a broken microphone feed (gaps of exact
// silence, very low level, audio arriving late) apart from Transcribe mishearing clear audio.
// It only reads the audio: nothing it does changes what is sent or translated.

import { LOGGER_PREFIX } from "../constants";

/** How long after Start the check runs. */
export const MIC_CHECK_SECONDS = 180;
const LINE_EVERY_MS = 1000;
// A run of exactly zero samples at least this long is a gap. A working microphone never produces one,
// even when nobody speaks (there is always a little noise), so a gap means the audio did not arrive.
const GAP_MIN_MS = 10;
// A 10 ms frame louder than this counts as voice. Rough: speech is usually between -40 and -10 dB.
const VOICE_DB = -45;
const FRAME_MS = 10;
// A sample this close to full scale is clipped (the microphone is too loud and distorts).
const CLIP_LEVEL = 0.99;

const toDb = (rms) => (rms > 0 ? Math.round(20 * Math.log10(rms)) : -Infinity);
const showDb = (db) => (Number.isFinite(db) ? `${db} dB` : "silent");
const showMs = (ms) => `${Math.round(ms)} ms`;
const plural = (n, word) => `${n} ${word}${n === 1 ? "" : "s"}`;

function emptyWindow() {
  return {
    samples: 0,
    sumSquares: 0,
    peak: 0,
    frames: 0,
    voiceFrames: 0,
    gaps: 0,
    longestGap: 0, // samples
    clipped: 0,
    blocks: 0,
    longestWait: 0, // ms between two blocks of audio
    sentBytes: 0,
    unsentBytes: 0,
    heard: 0,
  };
}

/**
 * @param {object} [opts]
 * @param {string} [opts.side]        label in the log lines
 * @param {number} [opts.seconds]     how long the check runs
 * @param {() => boolean} [opts.isMuted]  true while the agent is muted (a muted microphone sends silence)
 * @param {(line: string) => void} [opts.log]
 * @param {() => number} [opts.now]   milliseconds clock (tests)
 * @param {Function} [opts.setInterval]
 * @param {Function} [opts.clearInterval]
 */
export function createMicCheck({
  side = "agent",
  seconds = MIC_CHECK_SECONDS,
  isMuted = () => false,
  log = (line) => console.info(line),
  now = () => performance.now(),
  setInterval: startTimer = setInterval,
  clearInterval: stopTimer = clearInterval,
} = {}) {
  const prefix = `${LOGGER_PREFIX} - [MIC-CHECK] ${side}`;
  const startedAt = now();
  let finished = false;
  let sampleRate = 0;
  let lastBlockAt = startedAt;
  let zeroRun = 0; // samples in the current run of exact zeros
  let frameFill = 0;
  let frameSumSquares = 0;

  let current = emptyWindow();
  const total = { ...emptyWindow(), voiceSumSquares: 0, voiceSamples: 0, secondsWithGaps: 0, lowConfidence: 0, confidenceSum: 0, confidenceCount: 0 };

  const elapsed = () => (now() - startedAt) / 1000;
  const gapMinSamples = () => Math.max(1, Math.round((sampleRate * GAP_MIN_MS) / 1000));
  const frameSamples = () => Math.max(1, Math.round((sampleRate * FRAME_MS) / 1000));

  log(`${prefix} - started (temporary diagnostic: one line per second for ${seconds} s after Start)`);

  function endFrame() {
    const rms = Math.sqrt(frameSumSquares / frameFill);
    current.frames++;
    if (toDb(rms) >= VOICE_DB) {
      current.voiceFrames++;
      total.voiceSumSquares += frameSumSquares;
      total.voiceSamples += frameFill;
    }
    frameFill = 0;
    frameSumSquares = 0;
  }

  function line() {
    const w = current;
    const parts = [`${prefix} +${Math.round(elapsed())} s`];
    if (!w.blocks) {
      parts.push("no audio from the microphone");
    } else {
      const level = toDb(Math.sqrt(w.sumSquares / w.samples));
      const voice = w.frames ? Math.round((100 * w.voiceFrames) / w.frames) : 0;
      parts.push(`level ${showDb(level)} (peak ${showDb(toDb(w.peak))}), voice ${voice}%`);
      parts.push(w.gaps ? `gaps ${w.gaps} (longest ${showMs((1000 * w.longestGap) / sampleRate)})` : "gaps 0");
      parts.push(`clipped ${w.clipped}`);
      parts.push(`audio blocks ${w.blocks} (longest wait ${showMs(w.longestWait)})`);
      parts.push(`sent ${Math.round(w.sentBytes / 1024)} KB`);
    }
    if (w.unsentBytes) parts.push(`${Math.round(w.unsentBytes / 1024)} KB NOT sent (connection not open)`);
    if (w.heard) parts.push(`heard ${plural(w.heard, "phrase")}`);
    if (isMuted()) parts.push("MUTED");
    log(parts.join(" | "));
  }

  function addToTotal(w) {
    for (const key of ["samples", "sumSquares", "frames", "voiceFrames", "gaps", "clipped", "blocks", "sentBytes", "unsentBytes", "heard"]) {
      total[key] += w[key];
    }
    total.peak = Math.max(total.peak, w.peak);
    total.longestGap = Math.max(total.longestGap, w.longestGap);
    total.longestWait = Math.max(total.longestWait, w.longestWait);
    if (w.gaps) total.secondsWithGaps++;
  }

  function flush() {
    if (finished) return;
    line();
    addToTotal(current);
    current = emptyWindow();
    if (elapsed() >= seconds) finish();
  }

  function finish() {
    if (finished) return;
    finished = true;
    stopTimer(timer);
    const t = total;
    const voiceLevel = t.voiceSamples ? showDb(toDb(Math.sqrt(t.voiceSumSquares / t.voiceSamples))) : "none";
    const voice = t.frames ? Math.round((100 * t.voiceFrames) / t.frames) : 0;
    const avgConfidence = t.confidenceCount ? (t.confidenceSum / t.confidenceCount).toFixed(2) : "none";
    log(
      `${prefix} - finished after ${Math.round(elapsed())} s | voice ${voice}% of the time, voice level ${voiceLevel},` +
        ` peak ${showDb(toDb(t.peak))} | gaps ${t.gaps} in ${t.secondsWithGaps} s` +
        (t.gaps ? ` (longest ${showMs((1000 * t.longestGap) / (sampleRate || 1))})` : "") +
        ` | clipped ${t.clipped} | longest wait for audio ${showMs(t.longestWait)}` +
        ` | sent ${Math.round(t.sentBytes / 1024)} KB` +
        (t.unsentBytes ? `, ${Math.round(t.unsentBytes / 1024)} KB NOT sent` : "") +
        ` | heard ${plural(t.heard, "phrase")}, average confidence ${avgConfidence}, ${t.lowConfidence} under 0.5`,
    );
  }

  const timer = startTimer(flush, LINE_EVERY_MS);

  return {
    get active() {
      return !finished;
    },

    /** One block of microphone audio as Transcribe's pipeline receives it (Float32, -1..1). */
    noteAudio(chunk, rate) {
      if (finished || !chunk) return;
      if (rate) sampleRate = rate;
      if (!sampleRate) return;
      const at = now();
      current.blocks++;
      current.longestWait = Math.max(current.longestWait, at - lastBlockAt);
      lastBlockAt = at;
      const gapMin = gapMinSamples();
      const frameSize = frameSamples();
      for (let i = 0; i < chunk.length; i++) {
        const x = chunk[i];
        const square = x * x;
        current.sumSquares += square;
        const size = x < 0 ? -x : x;
        if (size > current.peak) current.peak = size;
        if (size >= CLIP_LEVEL) current.clipped++;
        if (x === 0) {
          zeroRun++;
          if (zeroRun === gapMin) current.gaps++;
          if (zeroRun >= gapMin && zeroRun > current.longestGap) current.longestGap = zeroRun;
        } else {
          zeroRun = 0;
        }
        frameSumSquares += square;
        if (++frameFill >= frameSize) endFrame();
      }
      current.samples += chunk.length;
    },

    /** Audio handed to the translation connection; ok false when the connection was not open. */
    noteSent(byteCount, ok = true) {
      if (finished) return;
      if (ok) current.sentBytes += byteCount || 0;
      else current.unsentBytes += byteCount || 0;
    },

    /** A phrase Transcribe returned: { words, confidence, wholeSentence } as the proxy sends them. */
    notePhrase(text, about = {}) {
      if (finished) return;
      current.heard++;
      const confidence = Number.isFinite(about.confidence) ? about.confidence : null;
      if (confidence != null) {
        total.confidenceSum += confidence;
        total.confidenceCount++;
        if (confidence < 0.5) total.lowConfidence++;
      }
      const words = Number.isFinite(about.words) ? plural(about.words, "word") : "? words";
      const kind = about.wholeSentence ? "sentence on its own" : "part of a longer sentence";
      log(
        `${prefix} +${elapsed().toFixed(1)} s heard "${String(text).slice(0, 120)}"` +
          ` (${words}, confidence ${confidence ?? "none"}, ${kind})`,
      );
    },

    /** Ends the check early (Stop, call end) and prints the summary. */
    stop() {
      if (finished) return;
      flush();
      finish();
    },
  };
}
