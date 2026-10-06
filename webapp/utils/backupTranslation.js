// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
//
// fix 6: backup translation when Nova Sonic is down.
//
// Each side of the call (agent -> customer, customer -> agent) runs on Nova Sonic. When Nova Sonic fails
// on a side (it does not start, its stream fails, or it goes silent) or the forceBackupTranslation switch
// is on, that side is translated by Amazon Transcribe -> Amazon Translate -> Amazon Polly instead, one
// sentence at a time. Nova Sonic is restarted in the background (at most 3 attempts per failure); once a
// restart works, Nova Sonic takes over again at the next quiet moment.
//
// Everything here is independent of the page: timers, clocks, audio and services are passed in, so the
// behaviour can be tested in Node. main.js wires it to the call.
import { wordsContainedIn } from "./translationGuards";

export const BACKUP_MAX_ATTEMPTS = 3;
// Same spacing as the existing Nova Sonic reconnects: 1.5 s, 3 s, 4.5 s.
export const BACKUP_BACKOFF_MS = (attempt) => attempt * 1500;
// Transcribe sometimes closes one sentence as two results within a few hundred milliseconds.
export const BACKUP_JOIN_MS = 250;
// Nova Sonic is judged silent when a sentence Transcribe heard got no Nova Sonic event of any kind (not
// even its own transcript of what it heard) from GRACE_BEFORE before the sentence ended to WAIT after it.
export const SILENCE_WAIT_MS = 6000;
export const SILENCE_GRACE_BEFORE_MS = 3000;
// Sentences this short ("ok", "the") are not judged.
export const SILENCE_MIN_WORDS = 3;
export const SILENCE_MIN_CHARS = 12;
// A sentence that ends this soon after a Nova Sonic session started is not judged: the session may
// have heard only its end.
export const SILENCE_SESSION_SETTLE_MS = 4000;
// At most this many silence switches per side per call, so a line that confuses the check cannot make
// the call flip back and forth.
export const SILENCE_MAX_TRIGGERS = 2;
// Customer side (no Transcribe while Nova Sonic works): speech on the line, then no Nova Sonic event.
export const VOICE_THRESHOLD_RMS = 0.02;
export const VOICE_MIN_VOICED_MS = 2000;
export const VOICE_BURST_GAP_MS = 1000;
export const VOICE_WAIT_MS = 10000;
export const VOICE_MAX_TRIGGERS = 1;
// Handing back to Nova Sonic only at a quiet moment.
export const HANDOVER_POLL_MS = 250;
export const HANDOVER_MIN_RETURNING_MS = 1500;
export const HANDOVER_QUIET_AFTER_SENTENCE_MS = 4000;
export const HANDOVER_QUIET_NOVA_MS = 2500;
export const HANDOVER_QUIET_VOICE_MS = 1000;
// Without a working level meter, this long without a sentence counts as quiet.
export const HANDOVER_QUIET_NO_METER_MS = 6000;
// Polly MP3 is at most 48 kbit/s; assuming 32 kbit/s over-estimates how long a clip plays, which is the
// safe side when deciding the line is quiet.
const ASSUMED_MP3_BYTES_PER_SECOND = 4000;

const defaultTimers = {
  setTimeout: (fn, ms) => setTimeout(fn, ms),
  clearTimeout: (id) => clearTimeout(id),
  setInterval: (fn, ms) => setInterval(fn, ms),
  clearInterval: (id) => clearInterval(id),
};

const words = (text) => String(text || "").trim().split(/\s+/).filter(Boolean);

/**
 * True when `text` (what Transcribe heard on one side) is mostly words that were just spoken to that
 * side: the translation played to the customer coming back through their phone.
 * @param {string} text
 * @param {string[]} recentlySpoken
 */
export function isLikelyEcho(text, recentlySpoken) {
  if (words(text).length < 3 || !recentlySpoken?.length) return false;
  return wordsContainedIn(text, recentlySpoken.join(" ")) >= 0.7;
}

/**
 * Translates and speaks one side's sentences in order. Translations are fetched in parallel as the
 * sentences arrive, and delivered strictly in the order spoken.
 *
 * @param {object} opts
 * @param {string} opts.label
 * @param {(text: string) => Promise<{text: string, audio: Uint8Array|null, voiceLabel?: string}|null>} opts.translate
 * @param {(job: {text: string}, result: object|null) => Promise<void>} opts.deliver  shows and plays one result
 */
export function createBackupSpeaker({ label, translate, deliver, joinMs = BACKUP_JOIN_MS, retryDelayMs = 400, timers = defaultTimers, now = Date.now, log = console }) {
  const queue = [];
  let epoch = 0;
  let pendingText = "";
  let joinTimer = null;
  let running = null;
  let lastDeliveredAt = 0;
  let playbackEndsAt = 0;
  const waiters = [];

  async function translateWithRetry(text) {
    let result = await Promise.resolve()
      .then(() => translate(text))
      .catch(() => null);
    if (!result || !result.text) {
      await new Promise((resolve) => timers.setTimeout(resolve, retryDelayMs));
      result = await Promise.resolve()
        .then(() => translate(text))
        .catch(() => null);
    }
    return result && result.text ? result : null;
  }

  function settleWaiters() {
    if (!speaker.isIdle()) return;
    waiters.splice(0).forEach((resolve) => resolve());
  }

  function pump() {
    if (running) return;
    running = (async () => {
      while (queue.length) {
        const job = queue[0];
        let result = null;
        try {
          result = await job.result;
        } catch {
          result = null;
        }
        if (queue[0] === job) queue.shift();
        if (job.epoch !== epoch) continue;
        const deliverStartedAt = now();
        const bytes = result?.audio?.byteLength ?? result?.audio?.length ?? 0;
        if (bytes > 0) {
          // Whether or not the player resolves only when the clip has finished, the line is not quiet
          // before this estimate of its end.
          playbackEndsAt = Math.max(playbackEndsAt, deliverStartedAt) + Math.ceil((bytes / ASSUMED_MP3_BYTES_PER_SECOND) * 1000);
        }
        try {
          await deliver(job, result);
        } catch (e) {
          log.error?.(`[BACKUP] ${label} - could not deliver a sentence`, e);
        }
        lastDeliveredAt = now();
      }
    })().finally(() => {
      running = null;
      if (queue.length) pump();
      else settleWaiters();
    });
  }

  function enqueue(text, prefetched) {
    const job = { text, epoch, queuedAt: now(), result: null };
    job.result = prefetched
      ? Promise.resolve(prefetched)
          .catch(() => null)
          .then((r) => (r && r.text ? r : translateWithRetry(text)))
      : translateWithRetry(text);
    queue.push(job);
    pump();
    return job;
  }

  function flush() {
    timers.clearTimeout(joinTimer);
    joinTimer = null;
    const text = pendingText.trim();
    pendingText = "";
    if (text) enqueue(text);
  }

  const speaker = {
    /** A sentence Transcribe finished. Joined with one that follows within joinMs. */
    say(text) {
      const t = String(text || "").trim();
      if (!t) return;
      pendingText = pendingText ? `${pendingText} ${t}` : t;
      timers.clearTimeout(joinTimer);
      joinTimer = timers.setTimeout(flush, joinMs);
    },
    /** Speak at once, optionally with a translation already fetched (the fix 4 prefetch). */
    speakNow(text, prefetched) {
      const t = String(text || "").trim();
      if (!t) return;
      flush();
      enqueue(t, prefetched);
    },
    /** Nothing waiting, translating or playing (by the clip length, whichever ends later). */
    isIdle() {
      return !pendingText && !joinTimer && queue.length === 0 && !running && now() >= playbackEndsAt;
    },
    whenIdle() {
      if (speaker.isIdle()) return Promise.resolve();
      return new Promise((resolve) => waiters.push(resolve));
    },
    /** Drops everything not yet delivered; results still in flight are discarded when they arrive. */
    cancel() {
      epoch++;
      timers.clearTimeout(joinTimer);
      joinTimer = null;
      pendingText = "";
      queue.length = 0;
      playbackEndsAt = 0;
      settleWaiters();
    },
    get lastDeliveredAt() {
      return lastDeliveredAt;
    },
    get playbackEndsAt() {
      return playbackEndsAt;
    },
  };
  return speaker;
}

/**
 * One side's state: "nova" (Nova Sonic translates), "backup" (Transcribe + Translate + Polly translate),
 * "returning" (Nova Sonic restarted and listening, but muted until the next quiet moment).
 *
 * ops (all provided by main.js):
 *   leaveNova({reason, cause, speakInProgress})  stop Nova Sonic on this side and start the backup
 *   startNova(label) -> Promise<boolean|"busy">   start a Nova Sonic session in the background ("busy":
 *                                                 another restart is running, try again shortly)
 *   abandonNova()                                 stop a session that started after it was no longer wanted
 *   handoverReady(returningSince) -> boolean      the side is quiet enough to hand back to Nova Sonic
 *   afterHandover()                               Nova Sonic is back: stop the backup
 *   onStateChange(state, detail)                  banner, logs, counters
 *   isCallLive() -> boolean
 *   onNovaHealthy() / onNovaUnhealthy()           optional: remembered for the next calls
 */
export function createFailoverController({ label, ops, maxAttempts = BACKUP_MAX_ATTEMPTS, backoffMs = BACKUP_BACKOFF_MS, handoverPollMs = HANDOVER_POLL_MS, timers = defaultTimers, now = Date.now, log = console }) {
  let state = "nova";
  let cause = null; // "failure" | "switch" | "memory" when not on Nova Sonic
  let reason = "";
  let attempts = 0;
  let generation = 0;
  let attemptTimer = null;
  let attemptInFlight = false;
  let handoverTimer = null;
  let returningSince = 0;
  let backupSince = 0;

  const notify = (detail) => {
    try {
      ops.onStateChange?.(state, { reason, cause, attempts, maxAttempts, ...detail });
    } catch (e) {
      log.error?.(`[BACKUP] ${label} - state change handler failed`, e);
    }
  };

  function clearAttempt() {
    timers.clearTimeout(attemptTimer);
    attemptTimer = null;
  }

  function stopHandoverPoll() {
    timers.clearInterval(handoverTimer);
    handoverTimer = null;
  }

  function scheduleAttempt(delayMs) {
    clearAttempt();
    attemptTimer = timers.setTimeout(() => {
      attemptTimer = null;
      attempt();
    }, delayMs);
  }

  function enterBackup(newReason, newCause, { speakInProgress = false } = {}) {
    const from = state;
    stopHandoverPoll();
    if (from === "nova") backupSince = now();
    state = "backup";
    reason = newReason;
    cause = newCause;
    try {
      ops.leaveNova({ reason: newReason, cause: newCause, from, speakInProgress: speakInProgress && from === "nova" });
    } catch (e) {
      log.error?.(`[BACKUP] ${label} - could not switch to backup`, e);
    }
    notify({ from });
  }

  async function attempt() {
    if (state !== "backup" || cause === "switch" || attemptInFlight) return;
    if (!ops.isCallLive()) return;
    if (attempts >= maxAttempts) return;
    attempts++;
    const gen = generation;
    const n = attempts;
    attemptInFlight = true;
    notify({ attempting: n });
    let ok = false;
    let busy = false;
    try {
      const outcome = await ops.startNova(`${label}-RETRY-${n}`);
      busy = outcome === "busy";
      ok = outcome === true;
    } catch (e) {
      ok = false;
      log.warn?.(`[BACKUP] ${label} - Nova Sonic restart ${n}/${maxAttempts} failed`, e);
    } finally {
      attemptInFlight = false;
    }
    if (busy) {
      // Another restart (Nova Sonic's own renewal, a WebRTC refresh) was running: not an attempt.
      attempts--;
      if (gen === generation && state === "backup" && cause !== "switch") scheduleAttempt(1000);
      return;
    }
    if (gen !== generation || state !== "backup" || cause === "switch") {
      // The call ended, the switch went on, or another path moved the side on while this attempt ran.
      if (ok) {
        try {
          ops.abandonNova();
        } catch (e) {
          log.error?.(`[BACKUP] ${label} - could not stop an unwanted Nova Sonic session`, e);
        }
      }
      return;
    }
    if (ok) {
      ops.onNovaHealthy?.();
      beginReturning();
      return;
    }
    ops.onNovaUnhealthy?.();
    if (attempts < maxAttempts) {
      scheduleAttempt(backoffMs(attempts));
      notify({ failedAttempt: n });
    } else {
      notify({ failedAttempt: n, exhausted: true });
    }
  }

  function beginReturning() {
    state = "returning";
    returningSince = now();
    notify({});
    stopHandoverPoll();
    handoverTimer = timers.setInterval(() => {
      if (state !== "returning") {
        stopHandoverPoll();
        return;
      }
      let ready = false;
      try {
        ready = ops.handoverReady(returningSince) === true;
      } catch (e) {
        log.error?.(`[BACKUP] ${label} - handover check failed`, e);
      }
      if (!ready) return;
      stopHandoverPoll();
      const backupMs = now() - backupSince;
      state = "nova";
      cause = null;
      reason = "";
      attempts = 0;
      try {
        ops.afterHandover();
      } catch (e) {
        log.error?.(`[BACKUP] ${label} - handover cleanup failed`, e);
      }
      notify({ handedOver: true, backupMs });
    }, handoverPollMs);
  }

  return {
    get state() {
      return state;
    },
    get cause() {
      return cause;
    },
    get reason() {
      return reason;
    },
    get attempts() {
      return attempts;
    },
    /** Transcribe's sentences go to the backup, not to the Nova Sonic checks. */
    routesToBackup() {
      return state !== "nova";
    },
    /** Nova Sonic's output on this side is not played or shown. */
    suppressesNova() {
      return state !== "nova";
    },
    /**
     * Nova Sonic failed on this side (did not start, stream error, silent). Switches to the backup at once
     * and restarts Nova Sonic in the background. A failure while already on the backup is ignored.
     */
    novaFailed(why, { speakInProgress = true } = {}) {
      if (state === "backup") return false;
      if (!ops.isCallLive()) return false;
      enterBackup(why, "failure", { speakInProgress });
      ops.onNovaUnhealthy?.();
      if (attempts < maxAttempts) scheduleAttempt(backoffMs(attempts + 1));
      else notify({ exhausted: true });
      return true;
    },
    /**
     * At Start: this side starts on the backup ("switch", "memory" or "failure"). speakInProgress: what
     * Transcribe heard while Nova Sonic was trying to start is spoken by the backup.
     */
    startOnBackup(why, startCause, { speakInProgress = false } = {}) {
      generation++;
      clearAttempt();
      attempts = 0;
      enterBackup(why, startCause, { speakInProgress });
      if (startCause !== "switch") scheduleAttempt(backoffMs(1));
    },
    /** The switch went on: every side goes to the backup and stays there. */
    switchOn(why) {
      if (state === "backup" && cause === "switch") return;
      generation++;
      clearAttempt();
      if (state === "backup") {
        cause = "switch";
        reason = why;
        notify({});
        return;
      }
      enterBackup(why, "switch", { speakInProgress: true });
    },
    /** The switch went off: a side on the backup because of the switch tries Nova Sonic again now. */
    switchOff() {
      if (state !== "backup" || cause !== "switch") return;
      generation++;
      cause = "failure";
      reason = "switch turned off";
      attempts = 0;
      notify({});
      scheduleAttempt(0);
    },
    /**
     * A Nova Sonic session started through the existing restart path (7.5-minute renewal, WebRTC refresh,
     * language change) while this side was on the backup: treat it like a successful background attempt.
     */
    novaSessionStarted() {
      if (state === "nova" || state === "returning") return;
      if (cause === "switch") {
        ops.abandonNova();
        return;
      }
      generation++;
      clearAttempt();
      ops.onNovaHealthy?.();
      beginReturning();
    },
    /** Call over: back to the initial state, with every timer stopped. */
    reset() {
      generation++;
      clearAttempt();
      stopHandoverPoll();
      state = "nova";
      cause = null;
      reason = "";
      attempts = 0;
      attemptInFlight = false;
    },
  };
}

/**
 * Agent side, while Nova Sonic works: a sentence that Transcribe heard, followed by no Nova Sonic event at
 * all (no transcript of its own, no text, no audio), means the session is silent. Stricter than "slow":
 * a working Nova Sonic always reports at least what it heard.
 */
export function createSilenceWatchdog({ isArmed, onSilent, waitMs = SILENCE_WAIT_MS, graceBeforeMs = SILENCE_GRACE_BEFORE_MS, minWords = SILENCE_MIN_WORDS, minChars = SILENCE_MIN_CHARS, settleMs = SILENCE_SESSION_SETTLE_MS, maxTriggers = SILENCE_MAX_TRIGGERS, timers = defaultTimers, now = Date.now }) {
  let lastEventAt = 0;
  let sessionStartedAt = 0;
  let triggers = 0;
  const pending = new Set();

  return {
    noteNovaEvent() {
      lastEventAt = now();
    },
    noteSessionStart() {
      sessionStartedAt = now();
    },
    /** A sentence Transcribe finished. `session` is the Nova Sonic session live at that moment. */
    noteSentence(text, session) {
      if (!session || triggers >= maxTriggers || !isArmed(session)) return;
      const t = String(text || "").trim();
      if (t.length < minChars || words(t).length < minWords) return;
      const at = now();
      if (at - sessionStartedAt < settleMs) return;
      const id = timers.setTimeout(() => {
        pending.delete(id);
        if (triggers >= maxTriggers || !isArmed(session)) return;
        if (lastEventAt >= at - graceBeforeMs) return;
        triggers++;
        onSilent({ text: t, heardAt: at, lastEventAt });
      }, waitMs);
      pending.add(id);
    },
    cancel() {
      pending.forEach((id) => timers.clearTimeout(id));
      pending.clear();
    },
    reset() {
      this.cancel();
      triggers = 0;
      lastEventAt = 0;
      sessionStartedAt = 0;
    },
    get triggers() {
      return triggers;
    },
  };
}

/**
 * Customer side, while Nova Sonic works (no Transcribe then): a burst of speech on the customer's line
 * followed by no Nova Sonic event at all. Continuous sound (music, noise) never ends a burst, so it never
 * triggers; only speech-like bursts with pauses are judged.
 *
 * @param {{onSample(fn: (level: number|null) => void): () => void}} opts.meter
 */
export function createVoiceWatchdog({ meter, isArmed, currentSession, onSilent, threshold = VOICE_THRESHOLD_RMS, minVoicedMs = VOICE_MIN_VOICED_MS, burstGapMs = VOICE_BURST_GAP_MS, waitMs = VOICE_WAIT_MS, settleMs = SILENCE_SESSION_SETTLE_MS, maxTriggers = VOICE_MAX_TRIGGERS, timers = defaultTimers, now = Date.now }) {
  let lastEventAt = 0;
  let sessionStartedAt = 0;
  let triggers = 0;
  let burst = null; // { startedAt, lastVoicedAt, voicedMs, lastSampleAt }
  const pending = new Set();
  let unsubscribe = null;

  function onSample(level) {
    const t = now();
    if (level == null) return;
    if (level > threshold) {
      if (!burst) burst = { startedAt: t, lastVoicedAt: t, voicedMs: 0, lastSampleAt: t };
      burst.voicedMs += Math.min(t - burst.lastSampleAt, 250) || 100;
      burst.lastVoicedAt = t;
      burst.lastSampleAt = t;
      return;
    }
    if (!burst) return;
    burst.lastSampleAt = t;
    if (t - burst.lastVoicedAt < burstGapMs) return;
    const ended = burst;
    burst = null;
    if (ended.voicedMs < minVoicedMs || triggers >= maxTriggers) return;
    const session = currentSession();
    if (!session || !isArmed(session)) return;
    if (ended.startedAt - sessionStartedAt < settleMs) return;
    // waitMs after the speech ended, not after the pause was noticed.
    const id = timers.setTimeout(() => {
      pending.delete(id);
      if (triggers >= maxTriggers || !isArmed(session)) return;
      if (lastEventAt >= ended.startedAt - burstGapMs) return;
      triggers++;
      onSilent({ burstStartedAt: ended.startedAt, burstEndedAt: ended.lastVoicedAt, lastEventAt });
    }, Math.max(0, waitMs - (t - ended.lastVoicedAt)));
    pending.add(id);
  }

  return {
    start() {
      if (!unsubscribe && meter) unsubscribe = meter.onSample(onSample);
    },
    stop() {
      unsubscribe?.();
      unsubscribe = null;
      burst = null;
      pending.forEach((id) => timers.clearTimeout(id));
      pending.clear();
    },
    noteNovaEvent() {
      lastEventAt = now();
    },
    noteSessionStart() {
      sessionStartedAt = now();
    },
    reset() {
      this.stop();
      triggers = 0;
      lastEventAt = 0;
      sessionStartedAt = 0;
    },
    get triggers() {
      return triggers;
    },
  };
}

/**
 * Sound level of a MediaStream, sampled every pollMs with an AnalyserNode (which runs without being
 * connected to the speakers). Never throws: without Web Audio support it reports no samples, which the
 * watchdog and the handover check treat as "no information".
 */
export function createLevelMeter(audioContext, mediaStream, { pollMs = 100, threshold = VOICE_THRESHOLD_RMS, timers = defaultTimers, now = Date.now } = {}) {
  const listeners = new Set();
  let source = null;
  let analyser = null;
  let interval = null;
  let buffer = null;
  let lastVoicedAt = 0;
  let working = false;
  try {
    source = audioContext.createMediaStreamSource(mediaStream);
    analyser = audioContext.createAnalyser();
    analyser.fftSize = 2048;
    source.connect(analyser);
    buffer = new Float32Array(analyser.fftSize);
    working = true;
    interval = timers.setInterval(() => {
      let level = null;
      try {
        analyser.getFloatTimeDomainData(buffer);
        let sum = 0;
        for (let i = 0; i < buffer.length; i++) sum += buffer[i] * buffer[i];
        level = Math.sqrt(sum / buffer.length);
      } catch {
        level = null;
      }
      if (level != null && level > threshold) lastVoicedAt = now();
      listeners.forEach((fn) => {
        try {
          fn(level);
        } catch {
          /* a listener's failure must not stop the meter */
        }
      });
    }, pollMs);
  } catch {
    working = false;
  }
  return {
    get working() {
      return working;
    },
    get lastVoicedAt() {
      return lastVoicedAt;
    },
    onSample(fn) {
      listeners.add(fn);
      return () => listeners.delete(fn);
    },
    dispose() {
      timers.clearInterval(interval);
      interval = null;
      listeners.clear();
      try {
        source?.disconnect();
      } catch {
        /* already disconnected */
      }
      try {
        analyser?.disconnect();
      } catch {
        /* already disconnected */
      }
      source = null;
      analyser = null;
      working = false;
    },
  };
}

/**
 * Nova Sonic's view of the agent's microphone stream. Two differences from handing Nova Sonic the stream
 * itself: when the session's input loop ends, the microphone is NOT destroyed (the agent's Transcribe
 * listens to the same microphone and must keep hearing it while Nova Sonic is restarted), and close()
 * ends the session's input loop at once. Every explicit destroy() of the stream in main.js still applies.
 *
 * onFirstPull runs when the session starts reading. A drain (createStreamDrain) that kept the stream
 * empty while the session was starting stops there, so the session hears live audio, not a burst of
 * what was said while it started.
 */
export function createNovaInputView(stream, { onFirstPull } = {}) {
  let closed = false;
  let wake = null;
  let pulled = false;
  const view = {
    get closed() {
      return closed;
    },
    close() {
      closed = true;
      if (wake) {
        const resolve = wake;
        wake = null;
        resolve({ value: undefined, done: true });
      }
    },
    [Symbol.asyncIterator]() {
      const iterator = stream[Symbol.asyncIterator]();
      return {
        next: () => {
          if (closed) return Promise.resolve({ value: undefined, done: true });
          if (!pulled) {
            pulled = true;
            try {
              onFirstPull?.();
            } catch {
              /* the view must keep working */
            }
          }
          return new Promise((resolve) => {
            wake = resolve;
            iterator.next().then(
              (result) => {
                if (wake !== resolve) return; // closed meanwhile: this chunk is dropped
                wake = null;
                resolve(result);
              },
              () => {
                if (wake !== resolve) return;
                wake = null;
                resolve({ value: undefined, done: true });
              },
            );
          });
        },
        return: () => {
          closed = true;
          wake = null;
          return Promise.resolve({ value: undefined, done: true });
        },
      };
    },
  };
  return view;
}

/**
 * Reads and discards a stream nobody else is reading (the agent's microphone while Nova Sonic is not
 * running), so its queue does not grow without bound. Never calls return(), which would destroy it.
 */
export function createStreamDrain(stream) {
  let stopped = false;
  const iterator = stream[Symbol.asyncIterator]();
  (async () => {
    while (!stopped) {
      let result;
      try {
        result = await iterator.next();
      } catch {
        break;
      }
      if (result.done) break;
    }
  })();
  return {
    stop() {
      stopped = true;
    },
    get stopped() {
      return stopped;
    },
  };
}

/**
 * Keeps the forceBackupTranslation switch's value, refreshed every intervalMs. A failed read keeps the
 * last value; the first value is false until a read succeeds.
 */
export function createModePoller({ fetchMode, onChange, intervalMs = 30000, timers = defaultTimers, log = console }) {
  let forceBackup = false;
  let known = false;
  let interval = null;
  let failing = false;
  let inFlight = null;

  async function refresh() {
    if (inFlight) return inFlight;
    inFlight = (async () => {
      try {
        const mode = await fetchMode();
        const next = mode?.forceBackup === true;
        if (failing) log.info?.("[BACKUP] switch readable again");
        failing = false;
        const changed = !known ? next : next !== forceBackup;
        forceBackup = next;
        known = true;
        if (changed) onChange?.(forceBackup);
      } catch (e) {
        if (!failing) log.warn?.(`[BACKUP] could not read the switch, keeping ${forceBackup ? "ON" : "off"}`, e?.message || e);
        failing = true;
      } finally {
        inFlight = null;
      }
    })();
    return inFlight;
  }

  return {
    start() {
      if (interval) return;
      refresh();
      interval = timers.setInterval(refresh, intervalMs);
    },
    stop() {
      timers.clearInterval(interval);
      interval = null;
    },
    refresh,
    get forceBackup() {
      return forceBackup;
    },
  };
}

/** Per-call counters for the [BACKUP-SUMMARY] line. */
export function createBackupStats() {
  const keys = ["switches", "returns", "sentences", "delivered", "textOnly", "failed", "echoDropped", "failedAttempts", "backupMs"];
  const counts = { agent: {}, customer: {} };
  const reset = () => {
    for (const side of ["agent", "customer"]) keys.forEach((k) => (counts[side][k] = 0));
    counts.typed = 0;
  };
  reset();
  return {
    inc(side, key, n = 1) {
      if (counts[side] && key in counts[side]) counts[side][key] += n;
    },
    incTyped() {
      counts.typed++;
    },
    get(side, key) {
      return counts[side]?.[key] || 0;
    },
    hasActivity() {
      return counts.typed > 0 || ["agent", "customer"].some((s) => keys.some((k) => counts[s][k] > 0));
    },
    summary() {
      const part = (s) =>
        `${s}: switched ${counts[s].switches}, back to Nova ${counts[s].returns}, sentences ${counts[s].sentences},` +
        ` spoken ${counts[s].delivered}, text only ${counts[s].textOnly}, failed ${counts[s].failed},` +
        ` echo dropped ${counts[s].echoDropped}, failed restarts ${counts[s].failedAttempts},` +
        ` on backup ${Math.round(counts[s].backupMs / 1000)}s`;
      return `${part("agent")} | ${part("customer")} | typed via backup ${counts.typed}`;
    },
    reset,
  };
}
