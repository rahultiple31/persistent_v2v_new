// fix 12: the health light. Two small labels at the top right of the Transcription panel tell the agent how
// the call's network is doing (Good, Weak, Lost) and how translation is doing (Normal, Backup mode, Slow,
// Down). Hovering a label shows the numbers behind it.
//
// It only reads, every HEALTH_TICK_MS:
//  - Network, two parts; the label shows the worse of the two:
//    - Call audio: the softphone's own call statistics (getStats() of the Amazon Connect RTC session; the
//      Amazon Connect library reads the same numbers every second). They cover this computer <-> Amazon
//      Connect, not the customer's phone line.
//    - Translation link: this computer <-> the translation proxy, which carries the call's audio to be
//      translated on Nova Sonic and on the backup alike: a small timed request every LINK_CHECK_MS during a
//      call, the audio still waiting to be sent on the proxy connections, and connections that dropped
//      (fix 13: in a virtual desktop the call-audio part runs in the data centre and stays clean while
//      this part suffers).
//    Neither part sees the link between the agent's own computer and a virtual desktop.
//  - Translation: which engine each side is on, how the regular translation-mode check and the connections
//    to the proxy went, and how the backup's requests went (recordHealthEvent, called by proxyTransport.js).
//    Backup mode alone never means slow: Slow is only shown when something measured is slow.
//
// Nothing here is on the audio path, and a failure here never reaches a call or a translation.
// The limits below are starting values: tune them from the [HEALTH] lines in the browser console.

/** How often the light is updated. */
export const HEALTH_TICK_MS = 2000;

/** The network is judged over this much recent time, so one bad moment does not make the light flicker. */
export const NET_WINDOW_MS = 10000;
/** Share of the call's audio packets lost, in either direction, above which the network is Weak (%). */
export const NET_WEAK_LOSS_PERCENT = 3;
/** Average jitter (uneven arrival of the audio) above which the network is Weak (ms). */
export const NET_WEAK_JITTER_MS = 40;
/** Average round trip between this computer and Amazon Connect above which the network is Weak (ms). */
export const NET_WEAK_RTT_MS = 400;
/** No call audio received for this long means the network is Lost. Not judged while the call is on hold. */
export const NET_LOST_AFTER_MS = 5000;

// fix 13: the translation link (this computer <-> the translation proxy).
/** How often the translation link is checked during a call (a multiple of HEALTH_TICK_MS). */
export const LINK_CHECK_MS = 4000;
/** A link check that has not answered after this long counts as not answered. */
export const LINK_CHECK_TIMEOUT_MS = 3000;
/** The link's round trip is averaged over the checks of this much recent time. */
export const LINK_WINDOW_MS = 15000;
/** Average round trip to the translation proxy above which the network is Weak (ms). */
export const LINK_WEAK_RTT_MS = 300;
/** Link checks without an answer in a row before the network is Lost (one alone makes it Weak). */
export const LINK_LOST_AFTER_FAILURES = 2;
/**
 * Call audio waiting in this browser to be sent to the translation proxy, above which the network is Weak
 * (bytes, the largest of the last NET_WINDOW_MS). The call sends roughly 32 to 45 KB of audio a second per
 * stream, so this is about a second of audio that the network could not take.
 */
export const LINK_WEAK_BACKLOG_BYTES = 32 * 1024;
/** A proxy connection that dropped makes the network Weak for this long. */
export const LINK_DROP_MEMORY_MS = 30000;

/** A translation-mode check (every 30 s, see createModePoller) slower than this means Slow (ms). */
export const PROXY_SLOW_MS = 1500;
/** How long one translation-mode check counts. */
export const PROXY_CHECK_FRESH_MS = 75000;
/** Failed contacts with the proxy in a row (checks and connections) before translation is Down. */
export const PROXY_DOWN_AFTER_FAILURES = 2;
/** Average time of the latest backup requests above which translation is Slow (ms). */
export const BACKUP_SLOW_MS = 2500;
/** How long a backup request counts. */
export const BACKUP_MEMORY_MS = 60000;
/** How many of the latest backup requests are averaged. */
export const BACKUP_AVERAGED = 3;
/** Failed backup requests in a row, while a side is on the backup, before translation is Down. */
export const BACKUP_DOWN_AFTER_FAILURES = 2;

// A getStats() call that has not answered after this long is given up and a new one may start.
const STATS_STALE_MS = 10000;
// getStats() failing this many times in a row during a call shows the network as not known.
const STATS_FAILURES_UNKNOWN = 3;
const MAX_BACKUP_REQUESTS = 20;
// A link check still running after this long (it can wait for a token renewal) is given up, uncounted.
const LINK_STALE_MS = 15000;
const MAX_LINK_CHECKS = 10;
const MAX_LINK_DROPS = 20;

export const NETWORK_LIMITS = Object.freeze({
  windowMs: NET_WINDOW_MS,
  weakLossPercent: NET_WEAK_LOSS_PERCENT,
  weakJitterMs: NET_WEAK_JITTER_MS,
  weakRttMs: NET_WEAK_RTT_MS,
  lostAfterMs: NET_LOST_AFTER_MS,
});

export const LINK_LIMITS = Object.freeze({
  windowMs: LINK_WINDOW_MS,
  backlogWindowMs: NET_WINDOW_MS,
  weakRttMs: LINK_WEAK_RTT_MS,
  lostAfterFailures: LINK_LOST_AFTER_FAILURES,
  weakBacklogBytes: LINK_WEAK_BACKLOG_BYTES,
  dropMemoryMs: LINK_DROP_MEMORY_MS,
});

export const TRANSLATION_LIMITS = Object.freeze({
  proxySlowMs: PROXY_SLOW_MS,
  proxyCheckFreshMs: PROXY_CHECK_FRESH_MS,
  proxyDownAfterFailures: PROXY_DOWN_AFTER_FAILURES,
  backupSlowMs: BACKUP_SLOW_MS,
  backupMemoryMs: BACKUP_MEMORY_MS,
  backupAveraged: BACKUP_AVERAGED,
  backupDownAfterFailures: BACKUP_DOWN_AFTER_FAILURES,
});

const defaultTimers = {
  setInterval: (fn, ms) => setInterval(fn, ms),
  clearInterval: (id) => clearInterval(id),
};

const finite = (value) => (typeof value === "number" && Number.isFinite(value) ? value : null);
const average = (values) => {
  const known = values.filter((v) => v != null);
  return known.length ? known.reduce((sum, v) => sum + v, 0) / known.length : null;
};
const ms = (value) => (value == null ? "--" : `${Math.round(value)} ms`);
const percent = (value) => (value == null ? "--" : `${value.toFixed(1)} %`);
const kilobytes = (value) => (value == null ? "--" : `${Math.round(value / 1024)} KB`);

// ── What the proxy and the backup report ───────────────────────────────────────────────────────────────

/**
 * Keeps what proxyTransport.js reports until the light reads it. Events:
 *   { type: "proxyCheck", ok, ms, status }  the translation-mode check (every 30 s from sign-in)
 *   { type: "proxyConnect", ok }            a connection to the proxy opened, or could not be opened
 *   { type: "backupRequest", ok, ms }       one Translate + Polly request through the proxy
 *   { type: "linkDrop", code }              fix 13: an open proxy connection was cut (no closing handshake)
 * and, through noteBacklog (called for every audio frame, so it keeps only a number), the audio waiting to
 * be sent on a proxy connection.
 */
export function createHealthSignals({ now = Date.now } = {}) {
  const state = {
    proxyCheck: null, // the latest translation-mode check: { ok, ms, status, at }
    proxyFailStreak: 0, // failed contacts with the proxy in a row
    proxyLastProblem: null, // { kind: "check" | "connect", status, at }
    proxyLastOkAt: 0,
    backupRequests: [], // { ok, ms, at }, newest last
    linkDrops: [], // fix 13: { code, at }, newest last
    backlogPeak: 0, // fix 13: the most audio waiting to be sent (bytes) since takeBacklogPeak
  };
  return {
    /** fix 13: bytes still waiting to be sent on a proxy connection, as a frame of audio is sent. */
    noteBacklog(bytes) {
      if (typeof bytes === "number" && bytes > state.backlogPeak) state.backlogPeak = bytes;
    },
    /** fix 13: the most audio waiting since the previous call, then starts again from zero. */
    takeBacklogPeak() {
      const peak = state.backlogPeak;
      state.backlogPeak = 0;
      return peak;
    },
    record(event) {
      const at = now();
      switch (event?.type) {
        case "proxyCheck":
        case "proxyConnect": {
          const ok = event.ok === true;
          if (event.type === "proxyCheck") state.proxyCheck = { ok, ms: finite(event.ms), status: finite(event.status), at };
          if (ok) {
            state.proxyFailStreak = 0;
            state.proxyLastOkAt = at;
          } else {
            state.proxyFailStreak++;
            state.proxyLastProblem = { kind: event.type === "proxyCheck" ? "check" : "connect", status: finite(event.status), at };
          }
          break;
        }
        case "backupRequest":
          state.backupRequests.push({ ok: event.ok === true, ms: finite(event.ms), at });
          if (state.backupRequests.length > MAX_BACKUP_REQUESTS) state.backupRequests.shift();
          break;
        case "linkDrop":
          state.linkDrops.push({ code: finite(event.code), at });
          if (state.linkDrops.length > MAX_LINK_DROPS) state.linkDrops.shift();
          break;
        default:
          break;
      }
    },
    read() {
      return state;
    },
  };
}

/** The signals the page's light reads. */
export const healthSignals = createHealthSignals();

/** Reports one event to the health light. Never throws, so it cannot disturb what reports it. */
export function recordHealthEvent(event) {
  try {
    healthSignals.record(event);
  } catch {
    // The light is informational only.
  }
}

/** fix 13: reports the bytes still waiting to be sent on a proxy connection. Never throws. */
export function recordSendBacklog(bytes) {
  try {
    healthSignals.noteBacklog(bytes);
  } catch {
    // The light is informational only.
  }
}

// ── Network ────────────────────────────────────────────────────────────────────────────────────────────

/**
 * The numbers the light needs from a getStats() result of the Amazon Connect RTC session. `input` is the
 * customer's side of the call as this computer receives it; `output` is what the call sends, as Amazon
 * Connect reports receiving it (with the round trip). Counters are totals since the call's media started.
 */
export function readCallStats(stats) {
  const input = stats?.audio?.input?.[0];
  const output = stats?.audio?.output?.[0];
  return {
    received: finite(input?.packetsCount),
    receivedLost: finite(input?.packetsLost),
    jitterIn: finite(input?.jbMilliseconds),
    sent: finite(output?.packetsCount),
    sentLost: finite(output?.packetsLost),
    jitterOut: finite(output?.jbMilliseconds),
    rtt: finite(output?.rttMilliseconds),
  };
}

/**
 * Judges the network from the samples of the last NET_WINDOW_MS (oldest first, each { at, ...readCallStats }).
 * receivedSince: when call audio was last seen arriving.
 * fix 13: statistics without any usable number are "unknown", never "good".
 * @returns {{ state: "checking"|"unknown"|"good"|"weak"|"lost", lossIn: number|null, lossOut: number|null,
 *   jitter: number|null, rtt: number|null, flowing: boolean|null, onHold: boolean, reasons: string[] }}
 */
export function judgeNetwork({ samples, t, receivedSince = null, onHold = false, limits = NETWORK_LIMITS }) {
  const recent = (samples || []).filter((s) => t - s.at <= limits.windowMs);
  if (recent.length < 2) {
    return { state: "checking", lossIn: null, lossOut: null, jitter: null, rtt: null, flowing: null, onHold, reasons: [] };
  }
  const first = recent[0];
  const last = recent[recent.length - 1];
  const delta = (key) => (first[key] != null && last[key] != null ? last[key] - first[key] : null);

  const received = delta("received");
  const receivedLost = delta("receivedLost") == null ? null : Math.max(0, delta("receivedLost"));
  const lossIn = received != null && receivedLost != null && received + receivedLost > 0 ? (receivedLost * 100) / (received + receivedLost) : null;
  const sent = delta("sent");
  const sentLost = delta("sentLost") == null ? null : Math.max(0, delta("sentLost"));
  const lossOut = sent != null && sentLost != null && sent > 0 ? Math.min(100, (sentLost * 100) / sent) : null;

  const jitterIn = average(recent.map((s) => s.jitterIn));
  const jitterOut = average(recent.map((s) => s.jitterOut));
  const jitter = jitterIn == null ? jitterOut : jitterOut == null ? jitterIn : Math.max(jitterIn, jitterOut);
  const rtt = average(recent.map((s) => s.rtt));

  const silentMs = last.received != null && receivedSince != null ? t - receivedSince : null;
  const flowing = onHold || silentMs == null ? null : silentMs < limits.lostAfterMs;

  const reasons = [];
  if (flowing === false) {
    reasons.push(`no call audio received for ${Math.round(silentMs / 1000)} s`);
    return { state: "lost", lossIn, lossOut, jitter, rtt, flowing, onHold, reasons };
  }
  if (lossIn == null && lossOut == null && jitter == null && rtt == null && flowing == null) {
    return { state: "unknown", lossIn, lossOut, jitter, rtt, flowing, onHold, reasons };
  }
  if (lossIn != null && lossIn > limits.weakLossPercent) reasons.push(`${percent(lossIn)} of the incoming call audio lost`);
  if (lossOut != null && lossOut > limits.weakLossPercent) reasons.push(`${percent(lossOut)} of the outgoing call audio lost`);
  if (jitter != null && jitter > limits.weakJitterMs) reasons.push(`call audio jitter ${ms(jitter)}`);
  if (rtt != null && rtt > limits.weakRttMs) reasons.push(`call audio round trip ${ms(rtt)}`);
  return { state: reasons.length ? "weak" : "good", lossIn, lossOut, jitter, rtt, flowing, onHold, reasons };
}

/**
 * fix 13: judges the translation link, this computer <-> the translation proxy. Nova Sonic and the backup
 * both send the call's audio over it, so nothing here depends on the engine.
 *   checks:  the link checks of this call, oldest first, each { at, reached, ms }
 *   backlog: the audio waiting to be sent, oldest first, each { at, bytes } (the largest since the previous)
 *   drops:   proxy connections cut during this call, each { at, code }
 * @returns {{ state: "checking"|"good"|"weak"|"lost", rtt: number|null, backlog: number|null, drops: number,
 *   failures: number, reasons: string[] }}
 */
export function judgeLink({ checks, backlog, drops, t, limits = LINK_LIMITS }) {
  const all = checks || [];
  let failures = 0;
  for (let i = all.length - 1; i >= 0 && !all[i].reached; i--) failures++;
  const recent = all.filter((c) => t - c.at <= limits.windowMs && c.reached);
  const rtt = average(recent.map((c) => c.ms));
  const waiting = (backlog || []).filter((b) => t - b.at <= limits.backlogWindowMs).map((b) => b.bytes);
  const peak = waiting.length ? Math.max(...waiting) : null;
  const dropped = (drops || []).filter((d) => t - d.at <= limits.dropMemoryMs).length;

  const reasons = [];
  if (failures >= limits.lostAfterFailures) {
    reasons.push(`the translation proxy did not answer ${failures} checks in a row`);
    return { state: "lost", rtt, backlog: peak, drops: dropped, failures, reasons };
  }
  if (failures > 0) reasons.push("the translation proxy did not answer the last check");
  if (rtt != null && rtt > limits.weakRttMs) reasons.push(`round trip to the translation proxy ${ms(rtt)}`);
  if (peak != null && peak > limits.weakBacklogBytes) reasons.push(`${kilobytes(peak)} of call audio waiting to be sent for translation`);
  if (dropped > 0) reasons.push(`the connection to the translation proxy dropped ${dropped === 1 ? "once" : `${dropped} times`}`);
  const state = reasons.length ? "weak" : all.length ? "good" : "checking";
  return { state, rtt, backlog: peak, drops: dropped, failures, reasons };
}

// The label shows the worse part; a part that cannot be measured is never shown as good. A part that has
// no result yet (checking) does not hide the other part's result.
const NETWORK_RANK = { checking: -1, good: 0, unknown: 2, weak: 3, lost: 4 };

/**
 * fix 13: the network label from its two parts, call audio and the translation link (null when the light
 * has no link check).
 */
export function combineNetwork(call, link) {
  const callState = call?.state || "checking";
  const linkState = link?.state;
  const state = linkState && (NETWORK_RANK[linkState] ?? 0) > (NETWORK_RANK[callState] ?? 0) ? linkState : callState;
  return { state, call: call || null, link: link || null, reasons: [...(call?.reasons || []), ...(link?.reasons || [])] };
}

// ── Translation ────────────────────────────────────────────────────────────────────────────────────────

const ENGINE_LABELS = {
  nova: "Nova Sonic",
  backup: "backup (Transcribe + Translate + Polly)",
  returning: "backup; Nova Sonic takes over at the next pause",
};

/**
 * Judges translation. engine: { active, agent, customer } with each side "nova" | "backup" | "returning".
 * Down > Slow > Backup mode > Normal. Before Start: Down or Slow from the proxy alone, else Ready once the
 * proxy has answered.
 * @returns {{ state: "idle"|"ready"|"normal"|"backup"|"slow"|"down", withBackup: boolean, onBackup: string[],
 *   backupMs: number|null, reasons: string[] }}
 */
export function judgeTranslation({ engine, signals, t, limits = TRANSLATION_LIMITS }) {
  const active = engine?.active === true;
  const onBackup = active
    ? [
        engine.agent && engine.agent !== "nova" ? "agent → customer" : null,
        engine.customer && engine.customer !== "nova" ? "customer → agent" : null,
      ].filter(Boolean)
    : [];
  const reasons = [];

  const proxyDown = signals.proxyFailStreak >= limits.proxyDownAfterFailures;
  if (proxyDown) reasons.push(proxyProblemText(signals.proxyLastProblem));
  const check = signals.proxyCheck;
  const proxySlow = !proxyDown && !!check?.ok && check.ms != null && t - check.at <= limits.proxyCheckFreshMs && check.ms > limits.proxySlowMs;
  if (proxySlow) reasons.push(`the proxy took ${ms(check.ms)} to answer`);

  // The backup's requests only count while a side is on the backup.
  const requests = onBackup.length ? signals.backupRequests.filter((r) => t - r.at <= limits.backupMemoryMs) : [];
  const latest = requests.slice(-limits.backupDownAfterFailures);
  const backupFailing = latest.length >= limits.backupDownAfterFailures && latest.every((r) => !r.ok);
  if (backupFailing) reasons.push("the backup's translation requests are failing");
  const timed = requests.filter((r) => r.ok && r.ms != null).slice(-limits.backupAveraged);
  const backupMs = timed.length ? average(timed.map((r) => r.ms)) : null;
  const backupSlow = !backupFailing && backupMs != null && backupMs > limits.backupSlowMs;
  if (backupSlow) reasons.push(`backup translations take ${ms(backupMs)}`);

  let state;
  if (!active) state = proxyDown ? "down" : proxySlow ? "slow" : signals.proxyLastOkAt ? "ready" : "idle";
  else if (proxyDown || backupFailing) state = "down";
  else if (proxySlow || backupSlow) state = "slow";
  else if (onBackup.length) state = "backup";
  else state = "normal";
  return { state, withBackup: state === "slow" && onBackup.length > 0, onBackup, backupMs, reasons };
}

function proxyProblemText(problem) {
  if (problem?.kind === "connect") return "could not connect to the translation proxy";
  if (problem?.status) return `the translation proxy answered HTTP ${problem.status}`;
  return "the translation proxy did not answer";
}

// ── What the agent sees ────────────────────────────────────────────────────────────────────────────────

const NETWORK_VIEWS = {
  idle: { cls: "health-idle", icon: "bi-wifi", text: "Network: --" },
  good: { cls: "health-good", icon: "bi-wifi", text: "Network: Good" },
  weak: { cls: "health-warn", icon: "bi-wifi-1", text: "Network: Weak" },
  lost: { cls: "health-bad", icon: "bi-wifi-off", text: "Network: Lost" },
  unknown: { cls: "health-idle", icon: "bi-question-circle", text: "Network: Unknown" },
};

const TRANSLATION_VIEWS = {
  idle: { cls: "health-idle", icon: "bi-translate", text: "Translation: --" },
  ready: { cls: "health-idle", icon: "bi-translate", text: "Translation: Ready" },
  normal: { cls: "health-good", icon: "bi-check-circle-fill", text: "Translation: Normal" },
  backup: { cls: "health-backup", icon: "bi-arrow-left-right", text: "Translation: Backup mode" },
  slow: { cls: "health-warn", icon: "bi-hourglass-split", text: "Translation: Slow" },
  down: { cls: "health-bad", icon: "bi-x-octagon-fill", text: "Translation: Down" },
};

/** The label for a network judgement. */
export function networkView(network) {
  return NETWORK_VIEWS[network?.state] || NETWORK_VIEWS.idle;
}

/** The label for a translation judgement; Slow while on the backup says both. */
export function translationView(translation) {
  const view = TRANSLATION_VIEWS[translation?.state] || TRANSLATION_VIEWS.idle;
  return translation?.withBackup ? { ...view, text: "Translation: Slow · Backup mode" } : view;
}

/**
 * The hover text of the network label. fix 13: `network` is combineNetwork's result (its two parts), or
 * { state: "idle" } outside a call.
 */
export function networkTooltip(network) {
  const state = network?.state;
  if (!state || state === "idle") {
    return "Network\nShown during a call: how well the call's audio travels between this computer and Amazon Connect, and between this computer and the translation proxy.";
  }
  const lines = ["Network", ...callAudioLines(network.call)];
  if (network.link !== null && network.link !== undefined) lines.push(...linkLines(network.link));
  if (network.reasons?.length) lines.push(`Why: ${network.reasons.join("; ")}`);
  return lines.join("\n");
}

function callAudioLines(call) {
  const title = "Call audio, this computer ↔ Amazon Connect";
  const state = call?.state;
  if (!state || state === "checking") return [`${title}: checking…`];
  if (state === "unknown") return [`${title}: not known (the call's statistics are not available)`];
  const audio = call.onHold ? "on hold" : call.flowing === false ? "stopped" : call.flowing ? "flowing" : "--";
  return [
    `${title} (last ${Math.round(NET_WINDOW_MS / 1000)} s):`,
    `  Round trip ${ms(call.rtt)} · jitter ${ms(call.jitter)} · loss ${percent(call.lossIn)} in, ${percent(call.lossOut)} out · audio ${audio}`,
  ];
}

function linkLines(link) {
  const title = "Translation link, this computer ↔ translation proxy";
  if (link.state === "checking") return [`${title}: checking…`];
  return [
    `${title}:`,
    `  Round trip ${ms(link.rtt)} (last ${Math.round(LINK_WINDOW_MS / 1000)} s) · audio waiting to be sent ${kilobytes(link.backlog)} · drops ${link.drops} (last ${Math.round(LINK_DROP_MEMORY_MS / 1000)} s)`,
  ];
}

/** The hover text of the translation label. */
export function translationTooltip(translation, { engine, signals, t, callProblems }) {
  const lines = ["Translation"];
  if (engine?.active) {
    lines.push(`Agent → customer: ${ENGINE_LABELS[engine.agent] || "--"}`);
    lines.push(`Customer → agent: ${ENGINE_LABELS[engine.customer] || "--"}`);
  } else {
    lines.push("Not running. Starts with the call's translation.");
  }
  const check = signals?.proxyCheck;
  if (!check) lines.push("Proxy check: not yet");
  else {
    const ago = `${Math.max(0, Math.round((t - check.at) / 1000))} s ago`;
    lines.push(check.ok ? `Proxy check: ${ms(check.ms)}, ${ago}` : `Proxy check: failed${check.status ? ` (HTTP ${check.status})` : ""}, ${ago}`);
  }
  if (engine?.active) {
    lines.push(`Backup replies: ${translation?.onBackup?.length ? (translation.backupMs == null ? "--" : `${ms(translation.backupMs)} on average`) : "not in use"}`);
    if (callProblems != null) lines.push(`Problems this call: ${callProblems}`);
  }
  if (translation?.reasons?.length) lines.push(`Why: ${translation.reasons.join("; ")}`);
  return lines.join("\n");
}

/** Updates one label; the page is only touched where something changed. */
function renderPill(element, view, title) {
  if (!element) return;
  const cls = `health-pill ${view.cls}`;
  if (element.className !== cls) element.className = cls;
  const icon = element.querySelector?.("i");
  const iconCls = `bi ${view.icon}`;
  if (icon && icon.className !== iconCls) icon.className = iconCls;
  const text = element.querySelector?.(".health-text");
  if (text && text.textContent !== view.text) text.textContent = view.text;
  if (element.getAttribute?.("title") !== title) element.setAttribute?.("title", title);
}

// ── The light ──────────────────────────────────────────────────────────────────────────────────────────

/**
 * @param {object} opts
 * @param {{ network: Element|null, translation: Element|null }} opts.elements  the two labels
 * @param {() => object|null} opts.getSession  the call's Amazon Connect RTC session, or null outside a call
 * @param {() => boolean} [opts.isOnHold]  the call is on hold (its audio may pause)
 * @param {() => { active: boolean, agent: string, customer: string }} opts.getEngine
 * @param {() => number} [opts.getCallProblems]  Nova Sonic failures and lost backup sentences, this call
 * @param {(opts: { timeoutMs: number }) => Promise<{ reached: boolean, ms: number|null }|null>} [opts.checkLink]
 *   fix 13: one timed request to the translation proxy (proxyTransport.js pingProxy); null when nothing
 *   was measured. Without it the network label shows the call audio only.
 */
export function createHealthMonitor({
  elements,
  getSession,
  isOnHold = () => false,
  getEngine,
  getCallProblems = () => null,
  checkLink = null,
  signals = healthSignals,
  timers = defaultTimers,
  now = Date.now,
  log = console,
  tickMs = HEALTH_TICK_MS,
}) {
  let timer = null;
  let network = { state: "idle" }; // what the label shows: combineNetwork(callNetwork, link)
  let callNetwork = { state: "idle" };
  let translation = { state: "idle" };
  let samples = [];
  let session = null;
  let receivedSince = null;
  let statsFailures = 0;
  let statsGeneration = 0;
  let statsInFlightSince = null;
  // fix 13: the translation link of the current call.
  const hasLinkCheck = typeof checkLink === "function";
  let link = null;
  let linkChecks = [];
  let backlog = [];
  let callSince = 0;
  let lastLinkCheckAt = null;
  let linkGeneration = 0;
  let linkInFlightSince = null;
  let shown = { network: "", translation: "" };
  let errorLogged = false;

  // A state measured during this call; kept while a refreshed connection is checked again (2 s).
  const isJudged = (n) => n.state === "good" || n.state === "weak" || n.state === "lost";

  const safe = (fn, fallback) => {
    try {
      return fn();
    } catch {
      return fallback;
    }
  };

  function reportError(e) {
    if (errorLogged) return;
    errorLogged = true;
    safe(() => log.warn?.("[HEALTH] the health light hit an error; it keeps trying", e));
  }

  // One console line per change of a label, with the time (console lines have none) and the reason.
  function logChange(kind, before, after, detail) {
    const word = (text) => text.replace(/^[^:]*:\s*/, "");
    safe(() => log.info?.(`[HEALTH] ${new Date(now()).toISOString()} ${kind}: ${word(before)} -> ${word(after)}${detail ? ` | ${detail}` : ""}`));
  }

  function resetNetwork() {
    samples = [];
    receivedSince = null;
    statsFailures = 0;
    // fix 13: the translation link is judged per call too; a check still running is ignored.
    link = hasLinkCheck ? judgeLink({ checks: [], backlog: [], drops: [], t: now() }) : null;
    linkChecks = [];
    backlog = [];
    lastLinkCheckAt = null;
    linkGeneration++;
    linkInFlightSince = null;
    callSince = now();
    safe(() => signals.takeBacklogPeak?.());
  }

  function networkDetail() {
    if (network.reasons?.length) return network.reasons.join("; ");
    if (network.state !== "good") return "";
    const parts = [];
    const call = network.call;
    if (call?.state === "good") parts.push(`call audio: round trip ${ms(call.rtt)}, jitter ${ms(call.jitter)}, loss ${percent(call.lossIn)} in / ${percent(call.lossOut)} out`);
    if (network.link?.state === "good") parts.push(`translation link: round trip ${ms(network.link.rtt)}, audio waiting ${kilobytes(network.link.backlog)}`);
    return parts.join(" | ");
  }

  function renderNetwork() {
    const view = networkView(network);
    renderPill(elements?.network, view, networkTooltip(network));
    if (view.text !== shown.network) {
      if (shown.network) logChange("network", shown.network, view.text, networkDetail());
      shown.network = view.text;
    }
  }

  function updateTranslation() {
    const t = now();
    const engine = safe(() => getEngine?.(), null) || { active: false };
    const state = signals.read();
    translation = judgeTranslation({ engine, signals: state, t });
    const view = translationView(translation);
    const callProblems = engine.active ? safe(() => getCallProblems(), null) : null;
    renderPill(elements?.translation, view, translationTooltip(translation, { engine, signals: state, t, callProblems }));
    if (view.text !== shown.translation) {
      if (shown.translation) logChange("translation", shown.translation, view.text, translation.reasons.join("; "));
      shown.translation = view.text;
    }
  }

  // fix 13: one link check at a time, every LINK_CHECK_MS during a call. The tick does not wait for it: its
  // result counts from the next tick.
  function maybeCheckLink(t) {
    if (timer == null) return;
    if (linkInFlightSince != null && t - linkInFlightSince < LINK_STALE_MS) return;
    if (lastLinkCheckAt != null && t - lastLinkCheckAt < LINK_CHECK_MS) return;
    lastLinkCheckAt = t;
    const generation = ++linkGeneration;
    linkInFlightSince = t;
    let pending;
    try {
      pending = Promise.resolve(checkLink({ timeoutMs: LINK_CHECK_TIMEOUT_MS }));
    } catch (e) {
      pending = Promise.reject(e);
    }
    pending.then(
      (result) => {
        if (generation !== linkGeneration) return;
        linkInFlightSince = null;
        // No result: nothing was measured (for example signed out), so it neither passes nor fails.
        if (!result) return;
        linkChecks.push({ at: now(), reached: result.reached === true, ms: finite(result.ms) });
        if (linkChecks.length > MAX_LINK_CHECKS) linkChecks.shift();
      },
      () => {
        if (generation === linkGeneration) linkInFlightSince = null;
      },
    );
  }

  // fix 13: the translation link's numbers for this tick.
  function updateLink() {
    if (!hasLinkCheck) return;
    const t = now();
    const peak = safe(() => signals.takeBacklogPeak?.(), null);
    if (typeof peak === "number") {
      backlog.push({ at: t, bytes: peak });
      backlog = backlog.filter((b) => t - b.at <= NET_WINDOW_MS + tickMs);
    }
    maybeCheckLink(t);
    const drops = (safe(() => signals.read().linkDrops, null) || []).filter((d) => d.at >= callSince);
    link = judgeLink({ checks: linkChecks, backlog, drops, t });
  }

  async function updateNetwork() {
    const current = safe(() => getSession?.(), null) || null;
    if (!current || typeof current.getStats !== "function") {
      if (session) resetNetwork();
      session = null;
      callNetwork = { state: "idle" };
      link = null;
      network = { state: "idle" };
      return;
    }
    if (current !== session) {
      session = current;
      resetNetwork();
      if (!isJudged(callNetwork)) callNetwork = { state: "checking" };
    }
    // fix 13: the link is judged on every tick, also while a getStats() is still running.
    updateLink();
    network = combineNetwork(callNetwork, link);
    // One getStats() at a time; one that never answers is given up after STATS_STALE_MS.
    if (statsInFlightSince != null && now() - statsInFlightSince < STATS_STALE_MS) return;
    const generation = ++statsGeneration;
    statsInFlightSince = now();
    let stats = null;
    try {
      stats = await current.getStats();
    } catch {
      stats = null;
    } finally {
      if (generation === statsGeneration) statsInFlightSince = null;
    }
    if (generation !== statsGeneration || current !== session || timer == null) return;

    if (!stats) {
      statsFailures++;
      if (statsFailures >= STATS_FAILURES_UNKNOWN) callNetwork = { state: "unknown", reasons: [] };
      network = combineNetwork(callNetwork, link);
      return;
    }
    statsFailures = 0;
    const at = now();
    const sample = { at, ...readCallStats(stats) };
    const previous = samples[samples.length - 1];
    // A refreshed WebRTC connection starts its counters again from zero: so does the light.
    if (previous && ((sample.received != null && previous.received != null && sample.received < previous.received) || (sample.sent != null && previous.sent != null && sample.sent < previous.sent))) {
      samples = [];
      receivedSince = null;
    }
    const before = samples[samples.length - 1];
    const onHold = safe(() => isOnHold() === true, false);
    if (receivedSince == null || onHold || sample.received == null || (before?.received != null && sample.received > before.received)) {
      receivedSince = at;
    }
    samples.push(sample);
    samples = samples.filter((s) => at - s.at <= NET_WINDOW_MS + tickMs);
    const judged = judgeNetwork({ samples, t: at, receivedSince, onHold });
    if (judged.state !== "checking" || !isJudged(callNetwork)) callNetwork = judged;
    network = combineNetwork(callNetwork, link);
  }

  async function tick() {
    try {
      updateTranslation();
    } catch (e) {
      reportError(e);
    }
    try {
      await updateNetwork();
      if (timer != null) renderNetwork();
    } catch (e) {
      reportError(e);
    }
  }

  return {
    start() {
      if (timer != null) return;
      timer = timers.setInterval(() => {
        tick();
      }, tickMs);
      tick();
    },
    stop() {
      if (timer == null) return;
      timers.clearInterval(timer);
      timer = null;
      statsGeneration++;
      statsInFlightSince = null;
      linkGeneration++;
      linkInFlightSince = null;
    },
    /** One update now (the timer calls this every tickMs). */
    tick,
    get network() {
      return network;
    },
    get translation() {
      return translation;
    },
  };
}
