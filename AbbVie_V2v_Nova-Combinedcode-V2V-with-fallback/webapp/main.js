// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import "./style.css";
import "bootstrap/dist/css/bootstrap.min.css";
import "bootstrap-icons/font/bootstrap-icons.css";
import "bootstrap/dist/js/bootstrap.bundle.min.js";
import "amazon-connect-streams";

import MicrophoneStream from "microphone-stream";

import {
  getConnectURLS,
  addUpdateLocalStorageKey,
  getLocalStorageValueByKey,
  isStringUndefinedNullEmpty,
} from "./utils/commonUtility";
import { autoSetCustomerLanguageFromAttribute } from "./utils/phoneLanguageUtils";
import {
  AGENT_TRANSLATION_TO_AGENT_VOLUME,
  AUDIO_FEEDBACK_FILE_PATH,
  CUSTOMER_TRANSLATION_TO_CUSTOMER_VOLUME,
  LOGGER_PREFIX,
  NOVA_INTERPRETER_LANGUAGES,
  LANGUAGE_VOICE_ID_MAP,
} from "./constants";
import {
  completePendingSignOut,
  getLoginUrl,
  handleRedirect,
  logout,
  registerSessionHooks,
  setRedirectURI,
  startSessionExpiryWatch,
  startTokenRefreshTimer,
} from "./utils/authUtility";
import { AudioStreamManager } from "./managers/AudioStreamManager";
import { SessionTrackManager, TrackType } from "./managers/SessionTrackManager";
import { createMicrophoneStream } from "./utils/micStreamUtils";
import { MicWorkletStream } from "./utils/micWorkletStream";
import { RemoteStreamWorkletStream } from "./utils/remoteStreamWorkletStream";
import { NOVA_SONIC_VOICE_IDS, runNovaSonicTypedTextInterpretation, startNovaSonicInterpreterSession } from "./adapters/novaSonicAdapter";
import { synthesizeFallbackTranslation, synthesizeTargetSpeech } from "./adapters/translateFallbackAdapter";
import { TranscribeStreamAdapter } from "./adapters/TranscribeStreamAdapter";
import {
  createCallStats,
  CUSTOMER_CHECK_STAT_LABELS,
  customerMentionsTranslationTask,
  HeardUtterance,
  heardFromCustomer,
  heardLanguage,
  isMuchLongerThan,
  isSameUtterance,
  JudgedSentences,
  matchesHeard,
  mentionsTranslationTask,
  normalizeForCompare,
  RecentSpeech,
  SourceUtterance,
} from "./utils/translationGuards";
import { CONNECT_CONFIG, NOVA_SONIC_CONFIG, TRANSCRIBE_CONFIG, TRANSLATE_CONFIG, POLLY_CONFIG, COGNITO_CONFIG, PROXY_CONFIG, TRANSLATION_CONFIG } from "./config";
import { fetchTranslationMode, warmProxyConnections } from "./utils/proxyTransport";
import { createAppVersionWatch } from "./utils/appVersionWatch";
import {
  BACKUP_MAX_ATTEMPTS,
  HANDOVER_MIN_RETURNING_MS,
  HANDOVER_QUIET_AFTER_SENTENCE_MS,
  HANDOVER_QUIET_NO_METER_MS,
  HANDOVER_QUIET_NOVA_MS,
  HANDOVER_QUIET_VOICE_MS,
  createBackupSpeaker,
  createBackupStats,
  createFailoverController,
  createLevelMeter,
  createModePoller,
  createNovaInputView,
  createSilenceWatchdog,
  createStreamDrain,
  createVoiceWatchdog,
  isLikelyEcho,
} from "./utils/backupTranslation";
import { AudioContextManager } from "./managers/AudioContextManager";
import { AudioInputTestManager } from "./managers/InputTestManager";
import {
  initConversationTranscript,
  addConversationMessage,
  clearConversationTranscript,
} from "./conversationTranscript.js";
import { TurnAccumulator } from "./utils/turnAccumulator";

/**
 * One turn assembler per channel.
 *
 * Nova Sonic splits its ASR of a single utterance across several textOutput
 * events, repeats its ASSISTANT text once per generation stage, and Transcribe
 * closes a long sentence as several FINAL results. Writing each fragment
 * straight into a box with `textContent = chunk` left the box showing only the
 * last fragment, and the transcript panel — which scraped those boxes — copied
 * the truncation into the history. These accumulators merge the fragments and
 * commit one transcript bubble per turn with both halves intact.
 *
 * Element ids, not references: these are constructed at module scope, before
 * bindUIElements() runs, and resolve their divs lazily on first render.
 */
const CustomerTurn = new TurnAccumulator({
  label: "CUSTOMER",
  originalId: "customerTranscriptionTextOutputDiv",
  translatedId: "customerTranslatedTextOutputDiv",
  onCommit: (original, translated) => addTranscriptCard(original, translated, "toAgent"),
});

const AgentTurn = new TurnAccumulator({
  label: "AGENT",
  originalId: "agentTranscriptionTextOutputDiv",
  translatedId: "agentTranslatedTextOutputDiv",
  onCommit: (original, translated) => addTranscriptCard(original, translated, "fromAgent"),
});

const DEFAULT_VOICE_ID = "matthew";
// Matches the initial value set by loadInterpreterLanguages().

let connect = {};
let CurrentUser = {};
let CCP_V2V = {};

let CurrentAgentConnectionId;
let ConnectSoftPhoneManager;
// Mirrors the CCP mute button (agent.onMuteToggle). See applyAgentMuteState().
let IsAgentMuted = false;

// AudioContextManager to manage the AudioContext
let AudioContextMgr = new AudioContextManager();

// AgentMicTestManager to test agent's mic
let AgentMicTestManager;

// Agent mic stream fed to Amazon Nova Sonic (interpreter session)
let AmazonTranscribeToCustomerAudioStream;
// Customer remote stream fed to Amazon Nova Sonic (interpreter session)
let AmazonTranscribeFromCustomerAudioStream;

let CustomerNovaSession;
let AgentNovaSession;
let AgentTranscribeAdapter = null;

// Language/voice pinned for the lifetime of a call.
//
// Every session start and restart used to read the language <select> elements
// directly. Because the dropdowns stay enabled mid-call and nothing resets them
// between calls, that meant: (a) a mid-call change silently took effect at the
// next restart, up to 7.5 minutes later, and (b) a restart could adopt a
// different language than the session it was replacing. Capturing the pair once
// at session start makes a call's language immutable for that call, and
// contactId lets an in-flight restart detect that its call has ended.
let AgentSessionConfig = null;
let CustomerSessionConfig = null;

function captureSessionConfig(sourceSelect, targetSelect) {
  const sourceLang = sourceSelect.value;
  const targetLang = targetSelect.value;

  // Same language on both sides means there is nothing to translate. Nova Sonic
  // just echoes the speaker, the classifier cannot tell echo from translation
  // (they are identical), and the Translate fallback rejects an identical
  // language pair — so the call runs with no translation and nothing in the UI
  // says so. This is the failure the (now removed) onContactDestroyed reset
  // caused on outbound calls, and it is equally reachable by simply forgetting
  // to set the customer's language.
  if (sourceLang && targetLang && sourceLang === targetLang) {
    console.error(
      `${LOGGER_PREFIX} - session language pair is "${sourceLang}" -> "${targetLang}":` +
      ` both sides are the same language, so nothing will be translated`
    );
    showToast(
      `Both languages are set to the same value (${targetLang}). ` +
      `Select the customer's language — nothing will be translated.`,
      8000,
    );
  }

  return {
    sourceLang,
    targetLang,
    // Voice must match the TARGET language — a source-language voice makes Nova
    // Sonic drift back toward the source ("FIX 1").
    voiceId: getVoiceId(targetLang),
    contactId: CurrentAgentConnectionId,
  };
}

/** True when an in-flight restart belongs to a call that has since ended. */
function isStaleSessionConfig(config) {
  return !config || config.contactId !== CurrentAgentConnectionId;
}

/**
 * Re-pin the language pair and restart whichever sessions are live.
 *
 * A Nova Sonic session's system prompt and output voice are fixed at
 * sessionStart and cannot be changed on the open bidirectional stream, so a
 * mid-call language change can only be honoured by restarting.
 */
function applyLanguageChangeToLiveSessions() {
  if (!AgentNovaSession && !CustomerNovaSession) {
    // fix 6: a side on the backup has no Nova Sonic session, but still follows the new language.
    applyLanguageChangeToBackup();
    return; // nothing live to update
  }

  console.warn(`${LOGGER_PREFIX} - language changed mid-call — restarting live sessions`);
  showToast("Applying new language — translation will resume in a moment…", 5000);

  if (AgentNovaSession && !agentSessionRestarting) {
    AgentSessionConfig = captureSessionConfig(
      CCP_V2V.UI.agentTranslateFromLanguageSelect,
      CCP_V2V.UI.customerTranslateFromLanguageSelect,
    );
    agentSessionRestarting = true;
    const stale = AgentNovaSession;
    AgentNovaSession = undefined;
    Promise.resolve(stale.stop())
      .catch(() => {})
      .finally(async () => {
        try {
          if (AmazonTranscribeToCustomerAudioStream) {
            await restartAgentNovaSession({
              user: "", assistant: "", lastAssistant: "", lastSource: "",
            });
          }
        } finally {
          agentSessionRestarting = false;
        }
      });
  }

  if (CustomerNovaSession && !customerSessionRestarting) {
    CustomerSessionConfig = captureSessionConfig(
      CCP_V2V.UI.customerTranslateFromLanguageSelect,
      CCP_V2V.UI.agentTranslateFromLanguageSelect,
    );
    customerSessionRestarting = true;
    const stale = CustomerNovaSession;
    CustomerNovaSession = undefined;
    Promise.resolve(stale.stop())
      .catch(() => {})
      .finally(async () => {
        try {
          if (AmazonTranscribeFromCustomerAudioStream) {
            await restartCustomerNovaSession({
              user: "", assistant: "", lastAssistant: "", lastSource: "",
            });
          }
        } finally {
          customerSessionRestarting = false;
        }
      });
  }

  // fix 6: a side on the backup follows the new language too.
  applyLanguageChangeToBackup();
}

/**
 * fix 6: language change for a side that is not on Nova Sonic. Its language pair is pinned again (unless
 * the Nova Sonic branch above just did), and its Transcribe starts again in the new language; sentences
 * translated from then on use the new pair.
 */
function applyLanguageChangeToBackup() {
  if (!TranslationActive) return;
  const agentOnBackup = AgentFailover.state === "backup" && !AgentNovaSession;
  const customerOffNova = CustomerFailover.state !== "nova";
  if (!agentOnBackup && !customerOffNova) return;
  showToast("Applying new language to the backup translation…", 5000);
  if (agentOnBackup) {
    AgentSessionConfig = captureSessionConfig(
      CCP_V2V.UI.agentTranslateFromLanguageSelect,
      CCP_V2V.UI.customerTranslateFromLanguageSelect,
    );
    agentRestartBackupTranscribe().catch((e) =>
      console.error(`${LOGGER_PREFIX} - [BACKUP] agent - Transcribe did not restart in the new language`, e),
    );
  }
  if (customerOffNova) {
    // While returning to Nova Sonic, the branch above has already re-pinned it with the session restart.
    if (!CustomerNovaSession) {
      CustomerSessionConfig = captureSessionConfig(
        CCP_V2V.UI.customerTranslateFromLanguageSelect,
        CCP_V2V.UI.agentTranslateFromLanguageSelect,
      );
    }
    customerRestartBackupTranscribe("language change").catch((e) =>
      console.error(`${LOGGER_PREFIX} - [BACKUP] customer - Transcribe did not restart in the new language`, e),
    );
  }
}

// Restart guard flags — prevent double-restart if both proactive timer
// and onError fire simultaneously (e.g. during a network blip at ~8 min).
let customerSessionRestarting = false;
let agentSessionRestarting = false;

// Retry counters — prevent infinite restart loop when stream is permanently dead.
// Resets to 0 on successful restart or intentional stop.
let customerRestartAttempts = 0;
let agentRestartAttempts = 0;
const MAX_RESTART_ATTEMPTS = 3;

// SessionTrackManager to manage the current track streaming to the customer
let RTCSessionTrackManager;

// AudioStreamManager to manage the stream that goes to Customer
let ToCustomerAudioStreamManager;

// AudioStreamManager to manage the stream that goes to Agent
let ToAgentAudioStreamManager;

// RCA-FIX: Timestamp (ms) of the last RTCSessionTrackManager.replaceTrack()
// call. WebRTC jitter buffer takes ~1-2s to warm up after a track swap --
// confirmed by packetsCount=0 / audioLevel>0 in softphone metrics.
// Polly fallback audio played during that cold-start window renders in the
// local Web Audio graph but zero RTP packets reach the customer phone.
let rtcTrackReplacedAt = 0;
const RTC_WARMUP_MS = 2000;

// ─── fix 4: agent-side safety state that outlives a single Nova Sonic session ──
// Per-call counters, printed as [CALL-SUMMARY] when the agent's translation stops.
const CallStats = createCallStats();
// The agent-side fallback that is playing now. A restart waits for it instead of disposing the audio
// manager underneath it, which cut the customer off mid-sentence after every drift restart.
let AgentFallbackPlayback = Promise.resolve();
// Context-clearing restarts are rate-limited, so a session that keeps failing is not restarted in a
// loop (the fallback still covers each bad sentence meanwhile).
let lastAgentHygieneRestartAt = 0;
const AGENT_HYGIENE_RESTART_COOLDOWN_MS = 20000;

// Translate + Polly results fetched as soon as Transcribe has the agent's sentence, while Nova Sonic
// is still translating it. If Nova Sonic's output then fails a check, the fallback plays at once
// instead of starting a Translate + Polly round trip only then. Unused results are dropped.
const FALLBACK_PREFETCH_DEBOUNCE_MS = 350; // Transcribe may close a sentence as several segments
function createPrefetch(fetchAudio) {
  return {
    entries: new Map(), // text -> Promise<{ audio, text } | null>
    timer: null,
    pendingText: "",
    schedule(text) {
      clearTimeout(this.timer);
      const t = (text || "").trim();
      this.pendingText = t;
      if (!t || this.entries.has(t)) return;
      this.timer = setTimeout(() => this.start(t), FALLBACK_PREFETCH_DEBOUNCE_MS);
    },
    start(text) {
      if (this.pendingText === text) this.pendingText = "";
      if (this.entries.has(text)) return this.entries.get(text);
      if (!AgentSessionConfig) return null;
      const promise = fetchAudio(text).catch(() => null);
      this.entries.set(text, promise);
      while (this.entries.size > 6) this.entries.delete(this.entries.keys().next().value);
      return promise;
    },
    /** The prefetched result for this exact text, or null. Starts it now if it was still debouncing. */
    take(text) {
      const t = (text || "").trim();
      if (this.entries.has(t)) return this.entries.get(t);
      if (t && this.pendingText === t) {
        clearTimeout(this.timer);
        return this.start(t);
      }
      return null;
    },
    clear() {
      clearTimeout(this.timer);
      this.timer = null;
      this.pendingText = "";
      this.entries.clear();
    },
  };
}
const FallbackPrefetch = createPrefetch((text) =>
  synthesizeFallbackTranslation({
    sourceText: text,
    sourceLangCode: AgentSessionConfig.sourceLang,
    targetLangCode: AgentSessionConfig.targetLang,
    translateRegion: TRANSLATE_CONFIG.region,
    pollyRegion: POLLY_CONFIG.region,
    quiet: true,
  }),
);
// When Nova Sonic hears the agent already in the customer's language, that sentence is made ready to
// speak as it is heard, before Nova Sonic has even answered. Unused results are dropped.
const HeardSpeechPrefetch = createPrefetch((text) =>
  synthesizeTargetSpeech({
    text,
    targetLangCode: AgentSessionConfig.targetLang,
    translateRegion: TRANSLATE_CONFIG.region,
    pollyRegion: POLLY_CONFIG.region,
  }),
);
// The customer's words as the customer session hears them, so the agent session can tell when its
// microphone picked up the customer (see heardFromCustomer).
const RecentCustomerSpeech = new RecentSpeech();

// ─── fix 6: backup translation (Transcribe + Translate + Polly) when Nova Sonic is down ──────────────
//
// See utils/backupTranslation.js. Each side moves to the backup on its own when its Nova Sonic session
// fails (does not start, stream error, silent) or when the forceBackupTranslation switch is on, and comes
// back to Nova Sonic at the next quiet moment once a background restart works. While a side is on Nova
// Sonic, nothing here changes what it plays or shows.

const backupLog = {
  info: (...args) => console.info(`${LOGGER_PREFIX} -`, ...args),
  warn: (...args) => console.warn(`${LOGGER_PREFIX} -`, ...args),
  error: (...args) => console.error(`${LOGGER_PREFIX} -`, ...args),
};
const backupSleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// True from Start until Stop or the end of the call.
let TranslationActive = false;
// Per-call counters, printed as [BACKUP-SUMMARY] when translation stops.
const BackupStats = createBackupStats();
// What was spoken to the customer by either engine, so the customer's Transcribe can recognise it
// coming back through the customer's phone.
const RecentSpokenToCustomer = new RecentSpeech(undefined, 10000);
// A Nova Sonic failure is remembered this long: calls started meanwhile begin on the backup at once and
// try Nova Sonic in the background, instead of first waiting for it to fail again.
const NOVA_FAILURE_MEMORY_MS = 5 * 60_000;
let novaUnhealthyUntil = 0;
// Without a sentence for this long, sound on the line is noise, not speech.
const HANDOVER_NOISY_LINE_MS = 12000;
// A sentence the customer's Transcribe finishes this soon after the handover to Nova Sonic was spoken
// before it (Nova Sonic's output for it was muted), so the backup still speaks it.
const LATE_BACKUP_SENTENCE_MS = 3000;
// The forceBackupTranslation switch (Parameter Store, read through the proxy).
let ModePoller = null;

const AgentBackup = {
  accumulated: null, // the call's `accumulated`, kept in step with restartAgentNovaSession
  view: null, // Nova Sonic's view of the microphone (createNovaInputView)
  drain: null, // reads the microphone while Nova Sonic does not
  drainFor: null,
  meter: null, // microphone level, while handing back to Nova Sonic
  speaker: null,
  lastSentenceAt: 0,
  lastNovaEventAt: 0,
  turnAudioSeen: false, // Nova Sonic audio arrived for the sentence it is translating now
  refreshPending: false, // a WebRTC refresh happened while a background restart was running
  exhausted: false,
  since: 0,
};
const CustomerBackup = {
  accumulated: null,
  transcribe: null, // the customer's Transcribe, only while this side is not on Nova Sonic
  transcribeStarting: null,
  transcribeToken: 0,
  meter: null, // customer line level (silence check and handover)
  meterToken: 0,
  speaker: null,
  lastSentenceAt: 0,
  lastNovaEventAt: 0,
  handedOverAt: 0,
  exhausted: false,
  since: 0,
};
// The customer-side backup clip playing now; a customer restart waits for it, as the agent side does
// with AgentFallbackPlayback.
let CustomerBackupPlayback = Promise.resolve();
// Set while a restart or WebRTC refresh replaces an audio output, so the backup waits for the new one.
let agentOutputSwapping = false;
let customerOutputSwapping = false;

const AgentFailover = createFailoverController({
  label: "AGENT",
  log: backupLog,
  ops: {
    leaveNova: (info) => agentLeaveNova(info),
    startNova: (label) => agentStartNovaInBackground(label),
    abandonNova: () => agentAbandonNova(),
    handoverReady: (since) => handoverReady(AgentBackup, agentBackupSpeaker(), since),
    afterHandover: () => agentAfterHandover(),
    onStateChange: (state, detail) => onBackupStateChange("agent", state, detail),
    isCallLive: () => TranslationActive && !isStaleSessionConfig(AgentSessionConfig),
    onNovaHealthy: () => {
      novaUnhealthyUntil = 0;
    },
    onNovaUnhealthy: () => {
      novaUnhealthyUntil = Date.now() + NOVA_FAILURE_MEMORY_MS;
    },
  },
});

const CustomerFailover = createFailoverController({
  label: "CUSTOMER",
  log: backupLog,
  ops: {
    leaveNova: () => customerLeaveNova(),
    startNova: (label) => customerStartNovaInBackground(label),
    abandonNova: () => customerAbandonNova(),
    handoverReady: (since) => handoverReady(CustomerBackup, customerBackupSpeaker(), since),
    afterHandover: () => customerAfterHandover(),
    onStateChange: (state, detail) => onBackupStateChange("customer", state, detail),
    isCallLive: () => TranslationActive && !isStaleSessionConfig(CustomerSessionConfig),
    onNovaHealthy: () => {
      novaUnhealthyUntil = 0;
    },
    onNovaUnhealthy: () => {
      novaUnhealthyUntil = Date.now() + NOVA_FAILURE_MEMORY_MS;
    },
  },
});

// Agent side: a sentence Transcribe heard, and no Nova Sonic event of any kind about it.
const AgentSilenceWatch = createSilenceWatchdog({
  isArmed: (session) =>
    TranslationActive &&
    AgentFailover.state === "nova" &&
    !agentSessionRestarting &&
    !!AgentNovaSession &&
    (session === undefined || session === AgentNovaSession),
  onSilent: ({ text }) => {
    console.warn(
      `${LOGGER_PREFIX} - [BACKUP] agent - Nova Sonic reported nothing about "${text.slice(0, 80)}"` +
      ` (no transcript, no text, no audio) — treating it as down`,
    );
    AgentFailover.novaFailed("Nova Sonic stopped responding");
  },
});

// Customer side: speech on the customer's line, and no Nova Sonic event of any kind after it.
const CustomerLevelRelay = {
  listeners: new Set(),
  onSample(fn) {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  },
  emit(level) {
    this.listeners.forEach((fn) => fn(level));
  },
};
const CustomerVoiceWatch = createVoiceWatchdog({
  meter: CustomerLevelRelay,
  currentSession: () => CustomerNovaSession,
  isArmed: (session) =>
    TranslationActive &&
    CustomerFailover.state === "nova" &&
    !customerSessionRestarting &&
    !!session &&
    session === CustomerNovaSession,
  onSilent: () => {
    console.warn(
      `${LOGGER_PREFIX} - [BACKUP] customer - the customer spoke and Nova Sonic reported nothing at all — treating it as down`,
    );
    CustomerFailover.novaFailed("Nova Sonic stopped responding");
  },
});

const NOVA_OUTPUT_HANDLERS = new Set([
  "onUserText",
  "onUserTextRetraction",
  "onAssistantText",
  "onAssistantAudioWav",
  "onTurnComplete",
  "onInterrupted",
  "onEchoDetected",
]);

/**
 * fix 6: every Nova Sonic session's handlers pass through here. While the side is on Nova Sonic this
 * only notes that the session is alive (for the silence checks) and calls each handler unchanged. While
 * the side is on the backup, or waiting to hand back to Nova Sonic, the session's output is neither
 * played nor shown. An error from a session that has already been replaced is not acted on.
 *
 * @returns {{ handlers: object, bind: (session: object) => void }}
 */
function guardNovaHandlers(side, handlers) {
  const isAgent = side === "agent";
  const failover = () => (isAgent ? AgentFailover : CustomerFailover);
  const liveSession = () => (isAgent ? AgentNovaSession : CustomerNovaSession);
  let boundSession = null;
  if (isAgent) AgentSilenceWatch.noteSessionStart();
  else CustomerVoiceWatch.noteSessionStart();

  const wrapped = {};
  for (const [name, fn] of Object.entries(handlers)) {
    if (typeof fn !== "function") {
      wrapped[name] = fn;
    } else if (NOVA_OUTPUT_HANDLERS.has(name)) {
      wrapped[name] = (...args) => {
        noteNovaEvent(isAgent, name, args);
        if (failover().suppressesNova()) return undefined;
        if (isAgent && name === "onAssistantText" && typeof args[0] === "string" && args[2]?.stage !== "FINAL") {
          RecentSpokenToCustomer.add(args[0]);
        }
        return fn(...args);
      };
    } else if (name === "onError") {
      wrapped[name] = (...args) => {
        if (boundSession && boundSession !== liveSession()) {
          console.warn(
            `${LOGGER_PREFIX} - [BACKUP] ${side} - error from a Nova Sonic session that was already replaced — not acted on`,
            args[0],
          );
          return undefined;
        }
        return fn(...args);
      };
    } else {
      wrapped[name] = fn;
    }
  }
  return {
    handlers: wrapped,
    bind: (session) => {
      boundSession = session;
    },
  };
}

/** Any Nova Sonic event means the session is alive; the agent side also tracks its current sentence. */
function noteNovaEvent(isAgent, name, args) {
  const now = Date.now();
  if (isAgent) {
    AgentBackup.lastNovaEventAt = now;
    AgentSilenceWatch.noteNovaEvent();
    if (name === "onAssistantText" && args[2]?.stage !== "FINAL") AgentBackup.turnAudioSeen = false;
    else if (name === "onAssistantAudioWav") AgentBackup.turnAudioSeen = true;
    else if (name === "onTurnComplete") AgentBackup.turnAudioSeen = false;
  } else {
    CustomerBackup.lastNovaEventAt = now;
    CustomerVoiceWatch.noteNovaEvent();
  }
}

/** A side hands back to Nova Sonic only when nothing is being said, translated or played on it. */
function handoverReady(B, speaker, since) {
  const now = Date.now();
  if (now - since < HANDOVER_MIN_RETURNING_MS) return false;
  if (!speaker.isIdle()) return false;
  const sinceSentence = now - B.lastSentenceAt;
  if (sinceSentence < HANDOVER_QUIET_AFTER_SENTENCE_MS) return false;
  if (now - B.lastNovaEventAt < HANDOVER_QUIET_NOVA_MS) return false;
  if (B.meter?.working) {
    return now - B.meter.lastVoicedAt >= HANDOVER_QUIET_VOICE_MS || sinceSentence >= HANDOVER_NOISY_LINE_MS;
  }
  return sinceSentence >= HANDOVER_QUIET_NO_METER_MS;
}

async function waitForAudioOutput(getOutput, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const output = getOutput();
    if (output) return output;
    if (Date.now() >= deadline) return null;
    await backupSleep(50);
  }
}

// ── fix 6: agent side (agent -> customer) ──────────────────────────────────────────────────────────────

function agentBackupSpeaker() {
  if (!AgentBackup.speaker) {
    AgentBackup.speaker = createBackupSpeaker({
      label: "AGENT",
      log: backupLog,
      translate: (text) => {
        const config = AgentSessionConfig;
        if (!config) return Promise.resolve(null);
        return synthesizeFallbackTranslation({
          sourceText: text,
          sourceLangCode: config.sourceLang,
          targetLangCode: config.targetLang,
          translateRegion: TRANSLATE_CONFIG.region,
          pollyRegion: POLLY_CONFIG.region,
          quiet: true,
        });
      },
      deliver: agentBackupDeliver,
    });
  }
  return AgentBackup.speaker;
}

/** A sentence the agent's Transcribe finished while the agent side is not on Nova Sonic. */
function agentBackupSentence(text) {
  AgentBackup.lastSentenceAt = Date.now();
  setBackgroundColour(CCP_V2V.UI.agentTranscriptionTextOutputDiv, "bg-pale-yellow");
  AgentTurn.pushOriginal(text);
  updateLiveSentiment(CCP_V2V.UI.agentSentimentValue, text);
  BackupStats.inc("agent", "sentences");
  agentBackupSpeaker().say(text);
}

async function agentBackupDeliver(job, result) {
  if (!TranslationActive || isStaleSessionConfig(AgentSessionConfig)) return;
  if (!result) {
    BackupStats.inc("agent", "failed");
    console.error(`${LOGGER_PREFIX} - [BACKUP] agent - no translation for "${job.text.slice(0, 80)}" (Translate failed twice)`);
    return;
  }
  AgentTurn.pushTranslation(result.text);
  RecentSpokenToCustomer.add(result.text);
  if (!result.audio || !result.audio.length) {
    BackupStats.inc("agent", "textOnly");
    console.error(`${LOGGER_PREFIX} - [BACKUP] agent - translated text only, no audio: "${result.text.slice(0, 80)}"`);
    return;
  }
  const playback = agentBackupPlay(new Uint8Array(result.audio));
  // A restart waits for this before it replaces the customer's audio output (see restartAgentNovaSession).
  AgentFallbackPlayback = playback;
  const played = await playback;
  BackupStats.inc("agent", played ? "delivered" : "failed");
  if (played) {
    console.info(
      `${LOGGER_PREFIX} - [BACKUP] agent -> customer${result.voiceLabel ? ` | ${result.voiceLabel}` : ""} | "${result.text.slice(0, 80)}"`,
    );
  }
}

/** Plays one clip to the customer, and to the agent's monitor when "Stream translation to agent" is on. */
async function agentBackupPlay(u8) {
  try {
    const output = await waitForAudioOutput(() => (agentOutputSwapping ? null : ToCustomerAudioStreamManager));
    if (!output) {
      console.error(`${LOGGER_PREFIX} - [BACKUP] agent - no audio output to the customer, sentence not played`);
      return false;
    }
    const wantsMonitor =
      CCP_V2V.UI.agentStreamTranslationCheckbox.checked === true && ToAgentAudioStreamManager != null;
    // Both copies before the first playback: playAudioBuffer detaches the buffer it is given.
    const forCustomer = new Uint8Array(u8);
    const forAgent = wantsMonitor ? new Uint8Array(u8) : null;
    const warmupRemaining = rtcTrackReplacedAt + RTC_WARMUP_MS - Date.now();
    if (warmupRemaining > 0) await backupSleep(warmupRemaining);
    await output.playAudioBuffer(forCustomer);
    if (forAgent && ToAgentAudioStreamManager != null) {
      await ToAgentAudioStreamManager.playAudioBuffer(forAgent, AGENT_TRANSLATION_TO_AGENT_VOLUME);
    }
    return true;
  } catch (e) {
    console.error(`${LOGGER_PREFIX} - [BACKUP] agent - could not play a sentence`, e);
    return false;
  }
}

/**
 * Keeps the agent's microphone read while no Nova Sonic session reads it. Always a new reader: a Nova
 * Sonic session that started reading meanwhile may have taken the old reader's place in the stream.
 */
function agentDrainMicrophone() {
  const mic = AmazonTranscribeToCustomerAudioStream;
  AgentBackup.drain?.stop();
  AgentBackup.drain = null;
  AgentBackup.drainFor = null;
  if (!mic) return;
  AgentBackup.drain = createStreamDrain(mic);
  AgentBackup.drainFor = mic;
}

function agentStopDrain() {
  AgentBackup.drain?.stop();
  AgentBackup.drain = null;
  AgentBackup.drainFor = null;
}

/** The agent side leaves Nova Sonic (failover op). */
function agentLeaveNova({ speakInProgress }) {
  AgentSilenceWatch.cancel();
  const source = AgentBackup.accumulated?.source;
  // What the agent said that Nova Sonic had not translated yet. The sentence Nova Sonic was answering is
  // left out once its audio had started (the customer heard it, or fix 4 replaced it).
  if (speakInProgress && source) {
    const text = (source.isTurnOpen() && AgentBackup.turnAudioSeen ? source.pendingText() : source.current()).trim();
    if (text) {
      const prefetched = FallbackPrefetch.take(text);
      console.info(`${LOGGER_PREFIX} - [BACKUP] agent - speaking what Nova Sonic had not translated: "${text.slice(0, 80)}"`);
      BackupStats.inc("agent", "sentences");
      agentBackupSpeaker().speakNow(text, prefetched);
    }
  }
  source?.clear();
  FallbackPrefetch.clear();
  HeardSpeechPrefetch.clear();
  AgentBackup.turnAudioSeen = false;
  // Closing the view ends the session's input at once, without destroying the microphone that the
  // agent's Transcribe keeps listening to.
  const session = AgentNovaSession;
  AgentNovaSession = undefined;
  AgentBackup.view?.close();
  AgentBackup.view = null;
  if (session) Promise.resolve().then(() => session.stop()).catch(() => {});
  agentDrainMicrophone();
}

/** A Nova Sonic session on the existing microphone, started in the background (failover op). */
async function agentStartNovaInBackground(label) {
  if (agentSessionRestarting) return "busy";
  const config = AgentSessionConfig;
  const mic = AmazonTranscribeToCustomerAudioStream;
  const accumulated = AgentBackup.accumulated;
  if (!TranslationActive || isStaleSessionConfig(config) || !mic || !accumulated) return false;
  agentSessionRestarting = true;
  // The drain keeps the microphone empty until the session starts reading it, so the session hears
  // live audio rather than a burst of what was said while it was starting.
  agentDrainMicrophone();
  const drain = AgentBackup.drain;
  const view = createNovaInputView(mic, {
    onFirstPull: () => {
      drain?.stop();
      if (AgentBackup.drain === drain) {
        AgentBackup.drain = null;
        AgentBackup.drainFor = null;
      }
    },
  });
  let started = false;
  try {
    const guarded = guardNovaHandlers("agent", buildAgentSessionHandlers(accumulated));
    const session = await startNovaSonicInterpreterSession({
      audioStream: view,
      inputSampleRate: AudioContextMgr.getActualSampleRate(),
      sourceLangCode: config.sourceLang,
      targetLangCode: config.targetLang,
      voiceId: config.voiceId,
      handlers: guarded.handlers,
      sessionLabel: label,
    });
    guarded.bind(session);
    if (!TranslationActive || isStaleSessionConfig(AgentSessionConfig) || AmazonTranscribeToCustomerAudioStream !== mic) {
      view.close();
      Promise.resolve().then(() => session.stop()).catch(() => {});
      return false;
    }
    if (AgentSessionConfig !== config) {
      // The language changed while it started: start again in the new language (not a failed attempt).
      view.close();
      Promise.resolve().then(() => session.stop()).catch(() => {});
      return "busy";
    }
    AgentNovaSession = session;
    AgentBackup.view = view;
    agentRestartAttempts = 0;
    started = true;
    console.info(`${LOGGER_PREFIX} - [BACKUP] agent - Nova Sonic started again (${label})`);
    return true;
  } catch (e) {
    view.close();
    console.warn(`${LOGGER_PREFIX} - [BACKUP] agent - Nova Sonic did not start (${label}): ${e?.message || e}`);
    return false;
  } finally {
    agentSessionRestarting = false;
    if (!started && TranslationActive) agentDrainMicrophone();
    if (AgentBackup.refreshPending) {
      AgentBackup.refreshPending = false;
      agentApplyPendingRefresh();
    }
  }
}

/** Stops a session that started after it was no longer wanted (failover op). */
function agentAbandonNova() {
  const session = AgentNovaSession;
  AgentNovaSession = undefined;
  AgentBackup.view?.close();
  AgentBackup.view = null;
  if (session) Promise.resolve().then(() => session.stop()).catch(() => {});
  if (TranslationActive) agentDrainMicrophone();
}

/** Nova Sonic has taken the agent side back (failover op). */
function agentAfterHandover() {
  AgentBackup.meter?.dispose();
  AgentBackup.meter = null;
  // Nova Sonic's checks start clean: nothing the backup translated is judged against its next output.
  AgentBackup.accumulated?.source?.clear();
  FallbackPrefetch.clear();
  HeardSpeechPrefetch.clear();
  AgentBackup.turnAudioSeen = false;
}

async function agentStartMeter() {
  const mic = AmazonTranscribeToCustomerAudioStream?.getMediaStream?.();
  if (!mic || AgentBackup.meter) return;
  const audioContext = await AudioContextMgr.getAudioContext();
  if (AgentBackup.meter || AgentFailover.state !== "returning") return;
  AgentBackup.meter = createLevelMeter(audioContext, mic);
}

/**
 * New microphone capture and Transcribe for the agent side while it is on the backup (after a WebRTC
 * refresh, or when a failed restart left none).
 */
async function agentRebuildCapture(why) {
  const accumulated = AgentBackup.accumulated;
  if (!TranslationActive || !accumulated || isStaleSessionConfig(AgentSessionConfig)) return;
  console.warn(`${LOGGER_PREFIX} - [BACKUP] agent - new microphone capture and Transcribe (${why})`);
  if (AgentTranscribeAdapter) {
    const old = AgentTranscribeAdapter;
    AgentTranscribeAdapter = null;
    await old.stop().catch(() => {});
  }
  agentStopDrain();
  if (AmazonTranscribeToCustomerAudioStream) {
    try {
      AmazonTranscribeToCustomerAudioStream.destroy();
    } catch {
      /* ignore cleanup errors */
    }
    AmazonTranscribeToCustomerAudioStream = undefined;
  }
  try {
    const audioContext = await AudioContextMgr.getAudioContext();
    AmazonTranscribeToCustomerAudioStream = await MicWorkletStream.create(
      audioContext,
      getMicrophoneConstraints(CCP_V2V.UI.micSelect.value),
    );
    applyAgentMuteState();
    AgentTranscribeAdapter = new TranscribeStreamAdapter({
      audioContext,
      micMediaStream: AmazonTranscribeToCustomerAudioStream.getMediaStream(),
      languageCode: AgentSessionConfig.sourceLang,
      region: TRANSCRIBE_CONFIG.region,
      onTranscript: buildAgentTranscriptHandler(accumulated),
      onError: buildAgentTranscribeErrorHandler("backup"),
    });
    AgentTranscribeAdapter.start().catch((e) => buildAgentTranscribeErrorHandler("backup")(e));
    agentDrainMicrophone();
  } catch (e) {
    console.error(`${LOGGER_PREFIX} - [BACKUP] agent - could not capture the microphone for the backup`, e);
    showToast("Backup translation cannot hear the microphone. Stop and start translation again.", 8000);
  }
}

/** The agent's Transcribe in a new language, on the same microphone (language change on the backup). */
async function agentRestartBackupTranscribe() {
  const accumulated = AgentBackup.accumulated;
  const mic = AmazonTranscribeToCustomerAudioStream;
  if (!TranslationActive || !accumulated || !mic || isStaleSessionConfig(AgentSessionConfig)) return;
  const audioContext = await AudioContextMgr.getAudioContext();
  const old = AgentTranscribeAdapter;
  AgentTranscribeAdapter = new TranscribeStreamAdapter({
    audioContext,
    micMediaStream: mic.getMediaStream(),
    languageCode: AgentSessionConfig.sourceLang,
    region: TRANSCRIBE_CONFIG.region,
    onTranscript: buildAgentTranscriptHandler(accumulated),
    onError: buildAgentTranscribeErrorHandler("language change"),
  });
  AgentTranscribeAdapter.start().catch((e) => buildAgentTranscribeErrorHandler("language change")(e));
  old?.stop().catch(() => {});
}

/** A WebRTC refresh that arrived while a background restart was running. */
function agentApplyPendingRefresh() {
  if (!TranslationActive || isStaleSessionConfig(AgentSessionConfig)) return;
  if (AgentNovaSession && !agentSessionRestarting) {
    // Returning to Nova Sonic: restart it the way a WebRTC refresh restarts a live session.
    agentSessionRestarting = true;
    const stale = AgentNovaSession;
    AgentNovaSession = undefined;
    AgentBackup.view?.close();
    AgentBackup.view = null;
    Promise.resolve(stale.stop())
      .catch(() => {})
      .finally(async () => {
        try {
          await restartAgentNovaSession(AgentBackup.accumulated);
        } finally {
          agentSessionRestarting = false;
        }
      });
  } else if (AgentFailover.state === "backup") {
    agentRebuildCapture("WebRTC refresh").catch((e) => console.error(`${LOGGER_PREFIX} - [BACKUP] agent - rebuild failed`, e));
  }
}

/** A full restart (restartAgentNovaSession) failed to start Nova Sonic: the backup takes over. */
function agentAfterFailedRestart(err) {
  const why = `Nova Sonic restart failed: ${err?.message || err}`;
  if (!AgentFailover.novaFailed(why)) agentDrainMicrophone();
  if (!AmazonTranscribeToCustomerAudioStream || !AgentTranscribeAdapter) {
    agentRebuildCapture("after a failed restart").catch((e) => console.error(`${LOGGER_PREFIX} - [BACKUP] agent - rebuild failed`, e));
  }
}

// ── fix 6: customer side (customer -> agent) ───────────────────────────────────────────────────────────

function customerRemoteStream() {
  return ConnectSoftPhoneManager?.getSession(CurrentAgentConnectionId)?._remoteAudioStream ?? null;
}

function customerBackupSpeaker() {
  if (!CustomerBackup.speaker) {
    CustomerBackup.speaker = createBackupSpeaker({
      label: "CUSTOMER",
      log: backupLog,
      translate: (text) => {
        const config = CustomerSessionConfig;
        if (!config) return Promise.resolve(null);
        return synthesizeFallbackTranslation({
          sourceText: text,
          sourceLangCode: config.sourceLang,
          targetLangCode: config.targetLang,
          translateRegion: TRANSLATE_CONFIG.region,
          pollyRegion: POLLY_CONFIG.region,
          quiet: true,
        });
      },
      deliver: customerBackupDeliver,
    });
  }
  return CustomerBackup.speaker;
}

/** A sentence the customer's Transcribe finished (it only runs while this side is not on Nova Sonic). */
function customerBackupSentence(text) {
  if (!TranslationActive) return;
  if (CustomerFailover.state === "nova" && Date.now() - CustomerBackup.handedOverAt > LATE_BACKUP_SENTENCE_MS) return;
  if (isLikelyEcho(text, RecentSpokenToCustomer.list().map((item) => item.text))) {
    BackupStats.inc("customer", "echoDropped");
    console.warn(
      `${LOGGER_PREFIX} - [ECHO] customer - the translation played to the customer came back through their phone — not translated: "${text.slice(0, 80)}"`,
    );
    return;
  }
  CustomerBackup.lastSentenceAt = Date.now();
  // The agent side's echo check (fix 4) needs the customer's words whichever engine hears them.
  RecentCustomerSpeech.add(text);
  setBackgroundColour(CCP_V2V.UI.customerTranscriptionTextOutputDiv, "bg-pale-yellow");
  CustomerTurn.pushOriginal(text);
  BackupStats.inc("customer", "sentences");
  customerBackupSpeaker().say(text);
}

async function customerBackupDeliver(job, result) {
  if (!TranslationActive || isStaleSessionConfig(CustomerSessionConfig)) return;
  if (!result) {
    BackupStats.inc("customer", "failed");
    console.error(`${LOGGER_PREFIX} - [BACKUP] customer - no translation for "${job.text.slice(0, 80)}" (Translate failed twice)`);
    return;
  }
  CustomerTurn.pushTranslation(result.text);
  if (!result.audio || !result.audio.length) {
    BackupStats.inc("customer", "textOnly");
    console.error(`${LOGGER_PREFIX} - [BACKUP] customer - translated text only, no audio: "${result.text.slice(0, 80)}"`);
    return;
  }
  const playback = customerBackupPlay(new Uint8Array(result.audio));
  CustomerBackupPlayback = playback;
  const played = await playback;
  BackupStats.inc("customer", played ? "delivered" : "failed");
  if (played) {
    console.info(
      `${LOGGER_PREFIX} - [BACKUP] customer -> agent${result.voiceLabel ? ` | ${result.voiceLabel}` : ""} | "${result.text.slice(0, 80)}"`,
    );
  }
}

/** Plays one clip to the agent, and to the customer when "Stream translation to customer" is on. */
async function customerBackupPlay(u8) {
  try {
    const output = await waitForAudioOutput(() => (customerOutputSwapping ? null : ToAgentAudioStreamManager));
    if (!output) {
      console.error(`${LOGGER_PREFIX} - [BACKUP] customer - no audio output to the agent, sentence not played`);
      return false;
    }
    const toCustomer =
      CCP_V2V.UI.customerStreamTranslationCheckbox.checked === true && ToCustomerAudioStreamManager != null;
    const forAgent = new Uint8Array(u8);
    const forCustomer = toCustomer ? new Uint8Array(u8) : null;
    await output.playAudioBuffer(forAgent);
    if (forCustomer && ToCustomerAudioStreamManager != null) {
      await ToCustomerAudioStreamManager.playAudioBuffer(forCustomer, CUSTOMER_TRANSLATION_TO_CUSTOMER_VOLUME);
    }
    return true;
  } catch (e) {
    console.error(`${LOGGER_PREFIX} - [BACKUP] customer - could not play a sentence`, e);
    return false;
  }
}

/** Starts the customer's Transcribe on the customer's WebRTC stream (only while not on Nova Sonic). */
function customerStartBackupTranscribe() {
  if (CustomerBackup.transcribe || CustomerBackup.transcribeStarting) return CustomerBackup.transcribeStarting;
  // A stop (customerStopBackupTranscribe) while this is starting bumps the token, so nothing starts late.
  const token = ++CustomerBackup.transcribeToken;
  CustomerBackup.transcribeStarting = (async () => {
    const remote = customerRemoteStream();
    if (!TranslationActive || !remote || isStaleSessionConfig(CustomerSessionConfig)) {
      if (TranslationActive && !remote) console.error(`${LOGGER_PREFIX} - [BACKUP] customer - no audio from the customer to transcribe`);
      return;
    }
    const audioContext = await AudioContextMgr.getAudioContext();
    if (token !== CustomerBackup.transcribeToken || !TranslationActive || CustomerFailover.state === "nova") return;
    const adapter = new TranscribeStreamAdapter({
      audioContext,
      micMediaStream: remote,
      languageCode: CustomerSessionConfig.sourceLang,
      region: TRANSCRIBE_CONFIG.region,
      onTranscript: customerBackupSentence,
      onError: (err) => {
        console.error(`${LOGGER_PREFIX} - [BACKUP] customer - Transcribe stopped`, err);
        showToast("Backup translation of the customer stopped. Stop and start translation again if this persists.", 8000);
      },
    });
    CustomerBackup.transcribe = adapter;
    console.info(`${LOGGER_PREFIX} - [BACKUP] customer - Transcribe started (${CustomerSessionConfig.sourceLang})`);
    // Not awaited: connecting can take a while (retries), and a stop must never wait for it.
    adapter.start().catch((err) => console.error(`${LOGGER_PREFIX} - [BACKUP] customer - Transcribe did not start`, err));
  })()
    .catch((err) => console.error(`${LOGGER_PREFIX} - [BACKUP] customer - Transcribe did not start`, err))
    .finally(() => {
      if (CustomerBackup.transcribeToken === token) CustomerBackup.transcribeStarting = null;
    });
  return CustomerBackup.transcribeStarting;
}

async function customerStopBackupTranscribe() {
  // Cancels a start still in progress, without waiting for it.
  CustomerBackup.transcribeToken++;
  CustomerBackup.transcribeStarting = null;
  const adapter = CustomerBackup.transcribe;
  CustomerBackup.transcribe = null;
  if (adapter) {
    await adapter.stop().catch(() => {});
    console.info(`${LOGGER_PREFIX} - [BACKUP] customer - Transcribe stopped`);
  }
}

/** The customer's Transcribe again, on the current stream and language (WebRTC refresh, language change). */
async function customerRestartBackupTranscribe(why) {
  console.info(`${LOGGER_PREFIX} - [BACKUP] customer - restarting Transcribe (${why})`);
  await customerStopBackupTranscribe();
  if (TranslationActive && CustomerFailover.state !== "nova") await customerStartBackupTranscribe();
}

/** Ends the Nova Sonic capture of the customer's stream (not the stream itself, which Connect owns). */
function customerReleaseNovaCapture() {
  const stream = AmazonTranscribeFromCustomerAudioStream;
  AmazonTranscribeFromCustomerAudioStream = undefined;
  if (stream) {
    try {
      stream.destroy();
    } catch {
      /* ignore cleanup errors */
    }
  }
}

/** The customer side leaves Nova Sonic (failover op). */
function customerLeaveNova() {
  const session = CustomerNovaSession;
  CustomerNovaSession = undefined;
  if (session) Promise.resolve().then(() => session.stop()).catch(() => {});
  customerReleaseNovaCapture();
  customerStartBackupTranscribe();
}

/** A customer Nova Sonic session started in the background (failover op). */
async function customerStartNovaInBackground(label) {
  if (customerSessionRestarting) return "busy";
  const config = CustomerSessionConfig;
  const accumulated = CustomerBackup.accumulated;
  if (!TranslationActive || isStaleSessionConfig(config) || !accumulated) return false;
  customerSessionRestarting = true;
  let stream = null;
  try {
    customerReleaseNovaCapture();
    stream = await captureFromCustomerAudioStream();
    AmazonTranscribeFromCustomerAudioStream = stream;
    // Kept empty until the session starts reading it (no burst of old audio); destroyed explicitly
    // whenever this side leaves Nova Sonic (customerReleaseNovaCapture).
    const drain = createStreamDrain(stream);
    const view = createNovaInputView(stream, { onFirstPull: () => drain.stop() });
    const guarded = guardNovaHandlers("customer", buildCustomerSessionHandlers(accumulated));
    const session = await startNovaSonicInterpreterSession({
      audioStream: view,
      inputSampleRate: AudioContextMgr.getActualSampleRate(),
      sourceLangCode: config.sourceLang,
      targetLangCode: config.targetLang,
      voiceId: config.voiceId,
      handlers: guarded.handlers,
      sessionLabel: label,
    });
    guarded.bind(session);
    if (!TranslationActive || isStaleSessionConfig(CustomerSessionConfig) || AmazonTranscribeFromCustomerAudioStream !== stream) {
      Promise.resolve().then(() => session.stop()).catch(() => {});
      if (AmazonTranscribeFromCustomerAudioStream === stream) customerReleaseNovaCapture();
      return false;
    }
    if (CustomerSessionConfig !== config) {
      // The language changed while it started: start again in the new language (not a failed attempt).
      Promise.resolve().then(() => session.stop()).catch(() => {});
      customerReleaseNovaCapture();
      return "busy";
    }
    CustomerNovaSession = session;
    customerRestartAttempts = 0;
    console.info(`${LOGGER_PREFIX} - [BACKUP] customer - Nova Sonic started again (${label})`);
    return true;
  } catch (e) {
    if (stream && AmazonTranscribeFromCustomerAudioStream === stream) customerReleaseNovaCapture();
    console.warn(`${LOGGER_PREFIX} - [BACKUP] customer - Nova Sonic did not start (${label}): ${e?.message || e}`);
    return false;
  } finally {
    customerSessionRestarting = false;
  }
}

/** Stops a customer session that started after it was no longer wanted (failover op). */
function customerAbandonNova() {
  const session = CustomerNovaSession;
  CustomerNovaSession = undefined;
  if (session) Promise.resolve().then(() => session.stop()).catch(() => {});
  customerReleaseNovaCapture();
}

/** Nova Sonic has taken the customer side back (failover op): its Transcribe is no longer needed. */
function customerAfterHandover() {
  CustomerBackup.handedOverAt = Date.now();
  customerStopBackupTranscribe();
}

/** The customer line's level meter, for the silence check and the handover (Nova Sonic mode too). */
async function customerStartMonitoring() {
  const token = ++CustomerBackup.meterToken;
  customerStopMonitoring();
  const remote = customerRemoteStream();
  if (!remote) return;
  const audioContext = await AudioContextMgr.getAudioContext();
  if (token !== CustomerBackup.meterToken || !TranslationActive) return;
  const meter = createLevelMeter(audioContext, remote);
  meter.onSample((level) => CustomerLevelRelay.emit(level));
  CustomerBackup.meter = meter;
  CustomerVoiceWatch.start();
}

function customerStopMonitoring() {
  CustomerBackup.meter?.dispose();
  CustomerBackup.meter = null;
}

/** A full restart (restartCustomerNovaSession) failed to start Nova Sonic: the backup takes over. */
function customerAfterFailedRestart(err) {
  customerReleaseNovaCapture();
  if (!CustomerFailover.novaFailed(`Nova Sonic restart failed: ${err?.message || err}`)) customerStartBackupTranscribe();
}

// ── fix 6: both sides ─────────────────────────────────────────────────────────────────────────────────

/** How a new call starts: on Nova Sonic (null), or on the backup because of the switch or a recent failure. */
function backupAtStart() {
  if (ModePoller?.forceBackup) return { reason: "switched on (forceBackupTranslation)", cause: "switch" };
  if (Date.now() < novaUnhealthyUntil) return { reason: "Nova Sonic failed on a recent call", cause: "memory" };
  return null;
}

/** A Nova Sonic failure the backup can cover. A sign-in problem is not one: the backup needs sign-in too. */
function isBackupWorthy(err) {
  const text = `${err?.name || ""} ${err?.message || err || ""}`;
  return !/not signed in|unauthori[sz]ed|code 4401|tokenExpired|authRequired|authTimeout/i.test(text);
}

function onBackupStateChange(side, state, detail) {
  const isAgent = side === "agent";
  const B = isAgent ? AgentBackup : CustomerBackup;
  const direction = isAgent ? "agent -> customer" : "customer -> agent";
  if (state === "backup" && detail.from === "nova") {
    B.since = Date.now();
    B.exhausted = false;
    BackupStats.inc(side, "switches");
    console.warn(`${LOGGER_PREFIX} - [BACKUP] ${direction}: now translated by Transcribe + Translate + Polly | ${detail.reason}`);
  } else if (state === "backup" && detail.from === "returning") {
    console.warn(`${LOGGER_PREFIX} - [BACKUP] ${direction}: Nova Sonic failed again before taking over | ${detail.reason}`);
  }
  if (detail.attempting) {
    console.info(`${LOGGER_PREFIX} - [BACKUP] ${direction}: restarting Nova Sonic in the background (${detail.attempting}/${detail.maxAttempts})`);
  }
  if (detail.failedAttempt) BackupStats.inc(side, "failedAttempts");
  if (detail.exhausted) {
    B.exhausted = true;
    console.warn(
      `${LOGGER_PREFIX} - [BACKUP] ${direction}: Nova Sonic did not restart after ${detail.maxAttempts} attempts — the backup continues for the rest of this call`,
    );
  }
  if (state === "returning") {
    B.exhausted = false;
    console.info(`${LOGGER_PREFIX} - [BACKUP] ${direction}: Nova Sonic is back; it takes over at the next pause`);
    if (isAgent) agentStartMeter().catch(() => {});
  }
  if (detail.handedOver) {
    BackupStats.inc(side, "returns");
    BackupStats.inc(side, "backupMs", detail.backupMs || 0);
    console.info(`${LOGGER_PREFIX} - [BACKUP] ${direction}: back on Nova Sonic after ${Math.round((detail.backupMs || 0) / 1000)} s on the backup`);
  }
  renderBackupNotice();
}

function renderBackupNotice() {
  try {
    const sides = [];
    if (AgentFailover.state !== "nova") sides.push(["agent → customer", AgentFailover, AgentBackup]);
    if (CustomerFailover.state !== "nova") sides.push(["customer → agent", CustomerFailover, CustomerBackup]);
    if (!TranslationActive || sides.length === 0) {
      hideBackupNotice();
      return;
    }
    const why = sides.some(([, c]) => c.cause === "switch") ? "switched on by your administrator" : "Nova Sonic is not responding";
    let next = " Nova Sonic is being restarted in the background.";
    if (sides.some(([, c]) => c.state === "returning")) next = " Nova Sonic is back and takes over at the next pause.";
    else if (sides.every(([, c]) => c.cause === "switch")) next = "";
    else if (sides.every(([, c, B]) => c.cause === "switch" || B.exhausted)) next = " Nova Sonic will be tried again on the next call.";
    showBackupNotice(
      `Backup translation (Transcribe + Translate + Polly) for ${sides.map(([label]) => label).join(" and ")}: ${why}.${next}`,
    );
  } catch (e) {
    console.error(`${LOGGER_PREFIX} - [BACKUP] could not show the backup notice`, e);
  }
}

function showBackupNotice(message) {
  if (typeof document === "undefined" || !document.body || !document.createElement) return;
  let banner = document.getElementById("backupNotice");
  if (!banner) {
    banner = document.createElement("div");
    banner.id = "backupNotice";
    banner.setAttribute("role", "status");
    Object.assign(banner.style, {
      position: "fixed",
      top: "52px",
      left: "50%",
      transform: "translateX(-50%)",
      zIndex: "10000",
      maxWidth: "min(640px, calc(100vw - 32px))",
      padding: "8px 14px",
      borderRadius: "6px",
      background: "#e8f1fb",
      color: "#0b3d6e",
      border: "1px solid #8db8e6",
      boxShadow: "0 2px 8px rgba(0, 0, 0, 0.15)",
      fontSize: "14px",
    });
    document.body.appendChild(banner);
  }
  if (banner.textContent !== message) banner.textContent = message;
  banner.style.display = "";
}

function hideBackupNotice() {
  if (typeof document === "undefined") return;
  const banner = document.getElementById("backupNotice");
  if (banner) banner.style.display = "none";
}

/** Reads the forceBackupTranslation switch through the proxy, from sign-in on. */
function startBackupSwitchWatch() {
  if (ModePoller) return;
  if (!PROXY_CONFIG.enabled) {
    console.info(`${LOGGER_PREFIX} - [BACKUP] the forceBackupTranslation switch is read through the proxy; not available without it`);
    return;
  }
  ModePoller = createModePoller({ fetchMode: () => fetchTranslationMode(), onChange: onBackupSwitchChanged, log: backupLog });
  ModePoller.start();
}

function onBackupSwitchChanged(on) {
  console.warn(`${LOGGER_PREFIX} - [BACKUP] forceBackupTranslation switch is ${on ? "ON" : "off"}`);
  if (!TranslationActive) return;
  if (on) {
    AgentFailover.switchOn("switched on (forceBackupTranslation)");
    CustomerFailover.switchOn("switched on (forceBackupTranslation)");
  } else {
    AgentFailover.switchOff();
    CustomerFailover.switchOff();
  }
  renderBackupNotice();
}

/** Start of a call's translation: a clean backup state. */
function resetBackupForCall() {
  AgentFailover.reset();
  CustomerFailover.reset();
  AgentSilenceWatch.reset();
  CustomerVoiceWatch.reset();
  BackupStats.reset();
  RecentSpokenToCustomer.clear();
  Object.assign(AgentBackup, { lastSentenceAt: 0, lastNovaEventAt: 0, turnAudioSeen: false, refreshPending: false, exhausted: false, since: 0 });
  Object.assign(CustomerBackup, { lastSentenceAt: 0, lastNovaEventAt: 0, handedOverAt: 0, exhausted: false, since: 0 });
  hideBackupNotice();
}

/** End of a call's translation: every backup timer, clip and capture stopped, and the summary logged. */
function stopBackupForCall() {
  const now = Date.now();
  if (AgentFailover.state !== "nova") BackupStats.inc("agent", "backupMs", now - AgentBackup.since);
  if (CustomerFailover.state !== "nova") BackupStats.inc("customer", "backupMs", now - CustomerBackup.since);
  AgentFailover.reset();
  CustomerFailover.reset();
  AgentSilenceWatch.reset();
  CustomerVoiceWatch.reset();
  AgentBackup.speaker?.cancel();
  CustomerBackup.speaker?.cancel();
  AgentBackup.view?.close();
  AgentBackup.view = null;
  agentStopDrain();
  AgentBackup.meter?.dispose();
  AgentBackup.meter = null;
  AgentBackup.refreshPending = false;
  hideBackupNotice();
  if (BackupStats.hasActivity()) console.info(`${LOGGER_PREFIX} - [BACKUP-SUMMARY] ${BackupStats.summary()}`);
  BackupStats.reset();
}

// ─── fix 7: checks on the customer -> agent translation ─────────────────────────────────────────────
//
// Until fix 7 everything the customer's Nova Sonic session said was played to the agent unchecked. On
// 2026-09-30 a customer session, fresh from its 7.5-minute renewal, spoke its reasoning to the agent
// ("Okay, translating the user's input…", "The tone seems neutral and patient…") for every sentence until
// the call ended. The customer session now runs fix 4's checks too (see buildCustomerSessionHandlers):
// a turn that fails is muted, and the agent hears Translate + Polly of what Nova Sonic heard the customer
// say instead. That is Nova Sonic's own transcript of the customer, so the customer's Transcribe still
// runs only while the customer side is on the backup.

// Per-call counters, printed as [CUSTOMER-CHECK-SUMMARY] when the agent's translation stops.
const CustomerCheckStats = createCallStats(CUSTOMER_CHECK_STAT_LABELS);
// Context-clearing restarts of the customer session, rate-limited like the agent side's.
let lastCustomerHygieneRestartAt = 0;
const CUSTOMER_HYGIENE_RESTART_COOLDOWN_MS = 20000;
let CustomerCheckSpeaker = null;

function customerCheckSpeaker() {
  if (!CustomerCheckSpeaker) {
    CustomerCheckSpeaker = createBackupSpeaker({
      label: "CUSTOMER-CHECK",
      log: backupLog,
      translate: customerCheckSynthesize,
      deliver: customerCheckDeliver,
    });
  }
  return CustomerCheckSpeaker;
}

/**
 * What Nova Sonic heard the customer say, in the agent's language: spoken as it is when Nova Sonic heard
 * it already in the agent's language (as fix 4 does on the agent side), translated otherwise.
 */
async function customerCheckSynthesize(text) {
  const config = CustomerSessionConfig;
  if (!config) return null;
  if (heardLanguage(text, config.sourceLang, config.targetLang, languageScore) === "target") {
    const spoken = await synthesizeTargetSpeech({
      text,
      targetLangCode: config.targetLang,
      translateRegion: TRANSLATE_CONFIG.region,
      pollyRegion: POLLY_CONFIG.region,
    }).catch(() => null);
    if (spoken && spoken.audio && spoken.audio.length) return { ...spoken, asHeard: true };
  }
  return synthesizeFallbackTranslation({
    sourceText: text,
    sourceLangCode: config.sourceLang,
    targetLangCode: config.targetLang,
    translateRegion: TRANSLATE_CONFIG.region,
    pollyRegion: POLLY_CONFIG.region,
    quiet: true,
  });
}

async function customerCheckDeliver(job, result) {
  if (!TranslationActive || isStaleSessionConfig(CustomerSessionConfig)) return;
  if (!result) {
    CustomerCheckStats.inc("fallbackFailed");
    console.error(`${LOGGER_PREFIX} - [CUSTOMER-FALLBACK] no translation for "${job.text.slice(0, 80)}" (Translate failed twice)`);
    return;
  }
  // Replaces what the turn showed: Nova Sonic's output for it was kept from the agent.
  CustomerTurn.setTranslation(result.text);
  if (!result.audio || !result.audio.length) {
    CustomerCheckStats.inc("fallbackFailed");
    console.error(`${LOGGER_PREFIX} - [CUSTOMER-FALLBACK] translated text only, no audio: "${result.text.slice(0, 80)}"`);
    return;
  }
  const playback = customerBackupPlay(new Uint8Array(result.audio));
  // A customer restart waits for this before it replaces the agent's audio output.
  CustomerBackupPlayback = playback;
  const played = await playback;
  if (!played) {
    CustomerCheckStats.inc("fallbackFailed");
    return;
  }
  CustomerCheckStats.inc("fallbackPlayed");
  if (result.asHeard) CustomerCheckStats.inc("fallbackAsHeard");
  console.info(
    `${LOGGER_PREFIX} - [CUSTOMER-FALLBACK] delivered to the agent | ` +
    `${result.asHeard ? "what Nova Sonic heard, as it is" : "Translate of what Nova Sonic heard"}` +
    `${result.voiceLabel ? ` | ${result.voiceLabel}` : ""} | "${result.text.slice(0, 80)}"`,
  );
}

/** Start of a call: fresh counters, no fallback left over, and the restart limit cleared. */
function resetCustomerChecksForCall() {
  CustomerCheckSpeaker?.cancel();
  CustomerCheckStats.reset();
  lastCustomerHygieneRestartAt = 0;
}

// Every setting in the two settings popups, logged at Start and whenever one changes, so a call log
// always shows which were on.
const AUDIO_SETTINGS = [
  ["customerStreamMicCheckbox", "Stream mic to agent"],
  ["customerStreamTranslationCheckbox", "Stream translation to customer"],
  ["customerAudioFeedbackEnabledCheckbox", "Customer audio feedback"],
  ["agentStreamTranslationCheckbox", "Stream translation to agent"],
  ["agentStreamMicCheckbox", "Stream mic to customer"],
  ["agentAudioFeedbackEnabledCheckbox", "Agent audio feedback"],
];

function describeAudioSettings() {
  const parts = AUDIO_SETTINGS.map(
    ([key, label]) => `${label}: ${CCP_V2V.UI[key]?.checked ? "ON" : "off"}`,
  );
  parts.push(`Mic-to-customer volume: ${CCP_V2V.UI.agentStreamMicVolume?.value}`);
  return parts.join(" | ");
}

function logAudioSettingChanges() {
  AUDIO_SETTINGS.forEach(([key, label]) => {
    CCP_V2V.UI[key]?.addEventListener("change", (event) => {
      console.info(`${LOGGER_PREFIX} - [SETTINGS] ${label} turned ${event.target.checked ? "ON" : "off"}`);
    });
  });
  CCP_V2V.UI.agentStreamMicVolume?.addEventListener("change", (event) => {
    console.info(`${LOGGER_PREFIX} - [SETTINGS] Mic-to-customer volume set to ${event.target.value}`);
  });
}

async function getAudioContext() {
  if (AudioContextMgr == null) {
    AudioContextMgr = new AudioContextManager();
  }
  const audioContext = await AudioContextMgr.getAudioContext();
  return audioContext;
}

async function getAgentMicTestManager() {
  if (AgentMicTestManager == null) {
    AgentMicTestManager = new AudioInputTestManager(await getAudioContext());
  }
  return AgentMicTestManager;
}

async function replaceRTCSessionTrackManager(peerConnection) {
  if (RTCSessionTrackManager != null) {
    await RTCSessionTrackManager.dispose();
  }
  RTCSessionTrackManager = new SessionTrackManager(
    peerConnection,
    await getAudioContext(),
  );
}

async function replaceToCustomerAudioStreamManager() {
  if (ToCustomerAudioStreamManager != null) {
    await ToCustomerAudioStreamManager.dispose();
  }
  ToCustomerAudioStreamManager = new AudioStreamManager(
    CCP_V2V.UI.toCustomerAudioElement,
    await getAudioContext(),
  );
}

async function replaceToAgentAudioStreamManager() {
  if (ToAgentAudioStreamManager != null) {
    await ToAgentAudioStreamManager.dispose();
  }
  ToAgentAudioStreamManager = new AudioStreamManager(
    CCP_V2V.UI.toAgentAudioElement,
    await getAudioContext(),
  );
}

window.addEventListener("load", () => {
  initializeApp();
});

async function initializeApp() {
  try {
    console.info(`${LOGGER_PREFIX} - initializeApp - Initializing app`);
    setRedirectURI();
    // A failed sign-in comes back with ?error=...; stop here rather than redirecting straight back into it.
    const urlParams = new URLSearchParams(window.location.search);
    if (urlParams.has("error")) {
      const reason = urlParams.get("error_description") || urlParams.get("error");
      console.error(`${LOGGER_PREFIX} - initializeApp - Sign-in failed: ${reason}`);
      window.history.replaceState({}, document.title, window.location.pathname);
      raiseError(`Sign-in failed: ${reason}\n\nReload the page to try again.`);
      return;
    }
    // Check if we're returning from Cognito login
    const isRedirect = await handleRedirect();
    if (isRedirect) {
      console.info(
        `${LOGGER_PREFIX} - initializeApp - Redirected from Cognito login`,
      );
      startTokenRefreshTimer();
      showApp();
      // Signed in and running: reset the redirect-loop guard (redirectToLogin), which is only for sign-ins
      // that keep failing. Reset after showApp, so a page that fails right after sign-in still trips it.
      try {
        sessionStorage.removeItem("loginRedirects");
      } catch (_) {
        // Storage unavailable: nothing to reset.
      }
      return;
    }

    // Tokens are held in the page's memory only (authUtility.js), so every other page load signs in again.
    console.info(
      `${LOGGER_PREFIX} - initializeApp - Not signed in, redirecting to login`,
    );
    redirectToLogin();
  } catch (error) {
    console.error(
      `${LOGGER_PREFIX} - initializeApp - Error initializing app:`,
      error,
    );
    redirectToLogin();
  }
}

/**
 * With SSO the login page redirects straight to the IdP and back, so a sign-in that keeps failing would
 * bounce between the app and the IdP forever. Allow 3 redirects a minute, then stop and tell the agent.
 */
async function redirectToLogin() {
  const now = Date.now();
  let recent = [];
  try {
    recent = JSON.parse(sessionStorage.getItem("loginRedirects") || "[]").filter((t) => now - t < 60 * 1000);
  } catch (_) {
    recent = [];
  }
  if (recent.length >= 3) {
    console.error(`${LOGGER_PREFIX} - redirectToLogin - Too many sign-in attempts, stopping redirect loop`);
    raiseError("Sign-in could not be completed. Please wait a minute and reload the page.");
    return;
  }
  recent.push(now);
  try {
    sessionStorage.setItem("loginRedirects", JSON.stringify(recent));
  } catch (_) {
    // Storage unavailable: redirect anyway.
  }
  window.location.href = await getLoginUrl();
}

function showApp() {
  initSessionGuard();
  onLoad();
}

// ── Sign-in session: never ended during a call ──────────────────────────────

// The Connect agent, once the CCP has initialised (set in onConnectInitialized).
let SessionAgent = null;

/** True while the agent has any contact, including after-call work. */
function isOnCall() {
  try {
    return SessionAgent != null && SessionAgent.getContacts().length > 0;
  } catch {
    return false;
  }
}

function initSessionGuard() {
  registerSessionHooks({ callActive: isOnCall, notify: showSessionNotice });
  startSessionExpiryWatch();
}

/**
 * Persistent banner for sign-in session notices. Signing in again reloads the
 * page, which would drop the softphone, so it is only offered between calls.
 */
function showSessionNotice({ type, expiresAt }) {
  let banner = document.getElementById("sessionNotice");
  if (!banner) {
    banner = document.createElement("div");
    banner.id = "sessionNotice";
    banner.setAttribute("role", "alert");
    Object.assign(banner.style, {
      position: "fixed",
      top: "8px",
      left: "50%",
      transform: "translateX(-50%)",
      zIndex: "10000",
      maxWidth: "min(640px, calc(100vw - 32px))",
      padding: "10px 14px",
      borderRadius: "6px",
      background: "#fff4e5",
      color: "#5c3b00",
      border: "1px solid #f0b95e",
      boxShadow: "0 2px 8px rgba(0, 0, 0, 0.15)",
      display: "flex",
      gap: "12px",
      alignItems: "center",
      fontSize: "14px",
    });
    document.body.appendChild(banner);
  }
  banner.replaceChildren();
  const text = document.createElement("span");
  if (type === "expiring") {
    const time = new Date(expiresAt).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
    text.textContent = TRANSLATION_CONFIG.enabled
      ? `Your sign-in ends at ${time}. Sign in again between calls to keep translation running.`
      : `Your sign-in ends at ${time}. Sign in again between calls.`;
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = "Sign in again";
    button.addEventListener("click", () => {
      if (isOnCall()) {
        showToast("Finish the current call first, then sign in again.", 5000);
        return;
      }
      logout();
    });
    banner.append(text, button);
  } else {
    text.textContent = TRANSLATION_CONFIG.enabled
      ? "Your sign-in has ended. This call continues, but translation may stop at its next restart. " +
        "You will be asked to sign in when the call ends."
      : "Your sign-in has ended. This call continues. You will be asked to sign in when the call ends.";
    banner.append(text);
  }
}

// ── Translation switch (SSM parameter translationEnabled) ───────────────────

// Set when a deploy switched translation off after this page loaded (see onAppVersionChange).
let TranslationSwitchedOff = false;

/**
 * True when a translation may start: this environment has voice translation (translationEnabled), and it has not
 * been switched off since the page loaded. Checked by every way a translation can start.
 */
function translationAllowed() {
  return TRANSLATION_CONFIG.enabled && !TranslationSwitchedOff;
}

/** For the start functions: false, with a note to the agent, when translation may not start. */
function checkTranslationAllowed(source) {
  if (translationAllowed()) return true;
  console.info(`${LOGGER_PREFIX} - ${source} - translation is not enabled here (translationEnabled); not started`);
  if (TranslationSwitchedOff) showToast("Voice translation has been switched off. Reload this page between calls.", 6000);
  return false;
}

/**
 * translationEnabled=false (Wave 1): the app is a plain softphone. The Customer, Agent and Transcription panels
 * stay in place, greyed out (style.css) and inert: nothing in them can be clicked, typed into or reached with the
 * Tab key. Their elements stay in the page because the code looks them up by ID. The CCP, Customer Information
 * and Audio Controls work as usual.
 */
function disableTranslationUI() {
  document.body.classList.add("translation-disabled");
  for (const id of ["divCustomerControls", "divAgentControls", "divTranscription"]) {
    const panel = document.getElementById(id);
    if (panel) panel.inert = true;
  }
}

// ── New version notice ──────────────────────────────────────────────────────

let AppVersionWatch = null;

/**
 * Every 5 minutes, and after each call, compares the deployed app with the one this page runs. When a deploy
 * changed it (new code, or a setting such as translationEnabled), a banner asks the agent to reload between
 * calls. The page never reloads itself: a reload drops the softphone and signs the agent in again.
 */
function startAppVersionWatch() {
  if (AppVersionWatch) return;
  AppVersionWatch = createAppVersionWatch({
    loadedMainScript: document.querySelector('script[type="module"][src]')?.getAttribute("src") ?? null,
    loadedConfig: window.WebappConfig ?? null,
    onChange: onAppVersionChange,
    log: (message) => console.info(`${LOGGER_PREFIX} - [VERSION] ${message}`),
  });
  AppVersionWatch.start();
}

function onAppVersionChange(change) {
  // Switching translation off takes effect at once: no new translation starts on this page, and calls continue
  // as plain calls. Switching it on needs the new page, which the banner asks for.
  TranslationSwitchedOff = change?.translationNowDisabled === true;
  if (TranslationSwitchedOff) console.warn(`${LOGGER_PREFIX} - [VERSION] translation switched off by a deploy; no new translation will start`);
  // fix 6's forceBackupTranslation switch is read through the proxy, which a switch-off removes.
  if (TranslationSwitchedOff) ModePoller?.stop();
  else if (TRANSLATION_CONFIG.enabled) ModePoller?.start();
  if (change) showUpdateNotice(change);
  else document.getElementById("updateNotice")?.remove();
}

function showUpdateNotice({ translationNowEnabled, translationNowDisabled }) {
  let banner = document.getElementById("updateNotice");
  if (!banner) {
    banner = document.createElement("div");
    banner.id = "updateNotice";
    banner.setAttribute("role", "status");
    Object.assign(banner.style, {
      position: "fixed",
      bottom: "16px",
      left: "50%",
      transform: "translateX(-50%)",
      zIndex: "10000",
      maxWidth: "min(640px, calc(100vw - 32px))",
      padding: "10px 14px",
      borderRadius: "6px",
      background: "#e8f1fb",
      color: "#0b3d6e",
      border: "1px solid #8db8e6",
      boxShadow: "0 2px 8px rgba(0, 0, 0, 0.15)",
      display: "flex",
      gap: "12px",
      alignItems: "center",
      fontSize: "14px",
    });
    document.body.appendChild(banner);
  }
  banner.replaceChildren();
  const text = document.createElement("span");
  text.textContent = translationNowEnabled
    ? "Voice translation is now available. Reload this page between calls to start using it."
    : translationNowDisabled
      ? "Voice translation has been switched off. Reload this page between calls."
      : "A new version of this app is available. Reload this page between calls to get it.";
  const button = document.createElement("button");
  button.type = "button";
  button.textContent = "Reload";
  button.addEventListener("click", () => {
    if (isOnCall()) {
      showToast("Finish the current call first, then reload.", 5000);
      return;
    }
    window.location.reload();
  });
  banner.append(text, button);
}

/**
 * Open the TCP+TLS connections to the AWS endpoints at page load, so the
 * Start button does not pay for DNS, the TCP handshake and the TLS handshake
 * on top of the service call itself.
 *
 * This deliberately starts NOTHING: no Nova Sonic session, no Transcribe
 * stream, no AWS request of any kind, and so nothing billable. It is a browser
 * resource hint — the socket is opened and left idle. Translation still begins
 * only when the agent presses Start, and a call that never uses translation
 * costs an unused socket and nothing else.
 *
 * `crossorigin` is required: the SDK's requests are CORS requests, and a
 * connection opened without it is not reused for them.
 */
function preconnectAwsEndpoints() {
  if (PROXY_CONFIG.enabled) {
    // Every AWS call goes through the same-origin proxy. Keep authenticated
    // proxy sockets open instead, so Start skips the connection handshake.
    warmProxyConnections();
    console.info(`${LOGGER_PREFIX} - warming translation proxy connections`);
    return;
  }
  const bedrockRegion = NOVA_SONIC_CONFIG.bedrockRegion;
  const hosts = [
    `https://bedrock-runtime.${bedrockRegion}.amazonaws.com`,
    `https://transcribestreaming.${TRANSCRIBE_CONFIG.region}.amazonaws.com`,
    `https://translate.${TRANSLATE_CONFIG.region}.amazonaws.com`,
    `https://polly.${POLLY_CONFIG.region}.amazonaws.com`,
    `https://cognito-identity.${COGNITO_CONFIG.region}.amazonaws.com`,
  ];
  for (const href of new Set(hosts)) {
    const link = document.createElement("link");
    link.rel = "preconnect";
    link.href = href;
    link.crossOrigin = "anonymous";
    document.head.appendChild(link);
  }
  console.info(`${LOGGER_PREFIX} - preconnected to ${new Set(hosts).size} AWS endpoints`);
}

const onLoad = async () => {
  console.info(`${LOGGER_PREFIX} - index loaded`);
  console.info(
    `${LOGGER_PREFIX} - voice translation is ${TRANSLATION_CONFIG.enabled ? "enabled" : "NOT enabled in this environment (translationEnabled=false)"}`,
  );
  if (TRANSLATION_CONFIG.enabled) {
    preconnectAwsEndpoints();
    // fix 6: the forceBackupTranslation switch, refreshed every 30 seconds.
    startBackupSwitchWatch();
  } else {
    disableTranslationUI();
  }
  startAppVersionWatch();
  bindUIElements();
  // ── Conversation Transcript panel (separate module) ──
  initConversationTranscript("divTranscriptContainer");
  initEventListeners();
  CCP_V2V.UI.logoutButton.style.display = "block";
  getDevices();
  setAudioElementsSinkIds();
  loadInterpreterLanguages();
  loadNovaCustomerVoices();
  loadNovaAgentVoices();
  initCCP(onConnectInitialized);
};

const bindUIElements = () => {
  window.connect.CCP_V2V = CCP_V2V;

  CCP_V2V.UI = {
    logoutButton: document.getElementById("logoutButton"),
    // divInstanceSetup: document.getElementById("divInstanceSetup"),
    // divMain: document.getElementById("divMain"),

    ccpContainer: document.querySelector("#ccpContainer"),

    spnCurrentConnectInstanceURL: document.getElementById(
      "spnCurrentConnectInstanceURL",
    ),
    tbConnectInstanceURL: document.getElementById("tbConnectInstanceURL"),
    btnSetConnectInstanceURL: document.getElementById(
      "btnSetConnectInstanceURL",
    ),
    btnStreamFile: document.getElementById("btnStreamFile"),
    btnStreamMic: document.getElementById("btnStreamMic"),
    btnRemoveAudioStream: document.getElementById("btnRemoveAudioStream"),

    //mic & speaker UI elements
    micSelect: document.getElementById("micSelect"),
    speakerSelect: document.getElementById("speakerSelect"),

    fromCustomerAudioElement: document.getElementById("remote-audio"),
    toCustomerAudioElement: document.getElementById("toCustomerAudioElement"),
    toAgentAudioElement: document.getElementById("toAgentAudioElement"),

    testAudioButton: document.getElementById("testAudioButton"),
    testMicButton: document.getElementById("testMicButton"),
    speakerSaveButton: document.getElementById("speakerSaveButton"),
    micSaveButton: document.getElementById("micSaveButton"),

    echoCancellationCheckbox: document.getElementById(
      "echoCancellationCheckbox",
    ),
    noiseSuppressionCheckbox: document.getElementById(
      "noiseSuppressionCheckbox",
    ),
    autoGainControlCheckbox: document.getElementById("autoGainControlCheckbox"),

    customerStartTranscriptionButton: document.getElementById(
      "customerStartTranscriptionButton",
    ),
    customerLoadingTranscriptionButton: document.getElementById(
      "customerLoadingTranscriptionButton",
    ),
    customerStopTranscriptionButton: document.getElementById(
      "customerStopTranscriptionButton",
    ),
    customerTranscriptionTextOutputDiv: document.getElementById(
      "customerTranscriptionTextOutputDiv",
    ),
    customerStreamMicCheckbox: document.getElementById(
      "customerStreamMicCheckbox",
    ),
    customerStreamTranslationCheckbox: document.getElementById(
      "customerStreamTranslationCheckbox",
    ),
    customerAudioFeedbackEnabledCheckbox: document.getElementById(
      "customerAudioFeedbackEnabledCheckbox",
    ),
    customerTranslateFromLanguageSelect: document.getElementById(
      "customerTranslateFromLanguageSelect",
    ),
    // customerTranslateToLanguageSelect: document.getElementById("customerTranslateToLanguageSelect"),
    // customerTranslateFromLanguageSaveButton removed — auto-saved via onChange
    // customerTranslateToLanguageSaveButton: document.getElementById("customerTranslateToLanguageSaveButton"),
    customerTranslatedTextOutputDiv: document.getElementById(
      "customerTranslatedTextOutputDiv",
    ),
    // customerNovaSonicVoiceSelect: document.getElementById("customerNovaSonicVoiceSelect"),
    // customerNovaSonicVoiceSaveButton: document.getElementById("customerNovaSonicVoiceSaveButton"),

    agentStartTranscriptionButton: document.getElementById(
      "agentStartTranscriptionButton",
    ),
    agentLoadingTranscriptionButton: document.getElementById(
      "agentLoadingTranscriptionButton",
    ),
    agentStopTranscriptionButton: document.getElementById(
      "agentStopTranscriptionButton",
    ),
    agentTranscriptionTextOutputDiv: document.getElementById(
      "agentTranscriptionTextOutputDiv",
    ),
    agentAudioFeedbackEnabledCheckbox: document.getElementById(
      "agentAudioFeedbackEnabledCheckbox",
    ),
    agentStreamMicCheckbox: document.getElementById("agentStreamMicCheckbox"),
    agentStreamMicVolume: document.getElementById("agentStreamMicVolume"),
    agentStreamTranslationCheckbox: document.getElementById(
      "agentStreamTranslationCheckbox",
    ),
    agentTranslateFromLanguageSelect: document.getElementById(
      "agentTranslateFromLanguageSelect",
    ),
    // agentTranslateToLanguageSelect: document.getElementById("agentTranslateToLanguageSelect"),
    // agentTranslateFromLanguageSaveButton removed — auto-saved via onChange
    // agentTranslateToLanguageSaveButton: document.getElementById("agentTranslateToLanguageSaveButton"),
    agentTranslateTextInput: document.getElementById("agentTranslateTextInput"),
    agentTranslateTextButton: document.getElementById(
      "agentTranslateTextButton",
    ),
    agentTranslatedTextOutputDiv: document.getElementById(
      "agentTranslatedTextOutputDiv",
    ),
    // agentNovaSonicVoiceSelect: document.getElementById("agentNovaSonicVoiceSelect"),
    agentNovaSonicVoiceSaveButton: document.getElementById(
      "agentNovaSonicVoiceSaveButton",
    ),
    // customerSentimentValue: document.getElementById("customerSentimentValue"),
    // agentSentimentValue: document.getElementById("agentSentimentValue"),

    //Transcript UI ElementsagentNovaSonicVoiceSelect
    divTranscriptContainer: document.getElementById("divTranscriptContainer"),
  };
};

const initEventListeners = () => {
  navigator.mediaDevices.addEventListener("devicechange", () => {
    console.info(`${LOGGER_PREFIX} - devicechange event fired`);
    getDevices();
  });

  CCP_V2V.UI.logoutButton.addEventListener("click", logout);

  // streamMic() and streamFile() replace the customer's entire outbound track
  // with the agent's raw microphone or an MP3, bypassing Nova Sonic completely.
  // Their buttons are display:none in index.html but the listeners were still
  // live, so any stray click, console call or extension could put untranslated
  // audio straight on the wire. Kept in the DOM (other code reads the elements)
  // but no longer clickable.
  // CCP_V2V.UI.btnStreamFile.addEventListener("click", streamFile);
  // CCP_V2V.UI.btnStreamMic.addEventListener("click", streamMic);
  CCP_V2V.UI.btnRemoveAudioStream.addEventListener("click", removeAudioTrack);

  //mic & speaker ui buttons
  CCP_V2V.UI.testAudioButton.addEventListener("click", testAudioOutput);
  CCP_V2V.UI.testMicButton.addEventListener("click", () => {
    if (CCP_V2V.UI.testMicButton.innerText === "Test") {
      testMicrophone();
      CCP_V2V.UI.testMicButton.innerText = "Stop";
    } else if (CCP_V2V.UI.testMicButton.innerText === "Stop") {
      stopTestMicrophone();
      CCP_V2V.UI.testMicButton.innerText = "Test";
    }
  });

  CCP_V2V.UI.speakerSaveButton.addEventListener("click", () =>
    addUpdateLocalStorageKey(
      "selectedSpeakerId",
      CCP_V2V.UI.speakerSelect.value,
    ),
  );
  CCP_V2V.UI.micSaveButton.addEventListener("click", () =>
    addUpdateLocalStorageKey("selectedMicId", CCP_V2V.UI.micSelect.value),
  );

  // ── REQ 1: Customer buttons are now hidden and controlled by the Agent
  // ──         Start/Stop buttons. Individual customer click listeners removed.
  // CCP_V2V.UI.customerStartTranscriptionButton.addEventListener(
  //   "click",
  //   customerStartTranscription,
  // );
  // CCP_V2V.UI.customerStopTranscriptionButton.addEventListener(
  //   "click",
  //   customerStopTranscription,
  // );

  CCP_V2V.UI.customerStreamMicCheckbox.addEventListener("change", (event) => {
    if (event.target.checked) {
      CCP_V2V.UI.fromCustomerAudioElement.muted = false;
    } else {
      CCP_V2V.UI.fromCustomerAudioElement.muted = true;
    }
  });

  CCP_V2V.UI.customerAudioFeedbackEnabledCheckbox.addEventListener(
    "change",
    (event) => {
      if (event.target.checked) {
        if (ToCustomerAudioStreamManager != null)
          ToCustomerAudioStreamManager.enableAudioFeedback(
            AUDIO_FEEDBACK_FILE_PATH,
          );
      } else {
        if (ToCustomerAudioStreamManager != null)
          ToCustomerAudioStreamManager.disableAudioFeedback();
      }
    },
  );

  // Customer language dropdown — auto-save on change + toast notification
  CCP_V2V.UI.customerTranslateFromLanguageSelect.addEventListener(
    "change",
    () => {
      const selectedOption =
        CCP_V2V.UI.customerTranslateFromLanguageSelect.options[
          CCP_V2V.UI.customerTranslateFromLanguageSelect.selectedIndex
        ];
      const languageName = selectedOption
        ? selectedOption.text
        : CCP_V2V.UI.customerTranslateFromLanguageSelect.value;
      const languageCode = CCP_V2V.UI.customerTranslateFromLanguageSelect.value;

      // Persist to localStorage — keeps the value in sync for the full app flow
      addUpdateLocalStorageKey("customerTranslateFromLanguage", languageCode);

      // Derive and persist the matching Nova Sonic voice ID for this language
      addUpdateLocalStorageKey(
        "customerNovaSonicVoiceId",
        getVoiceId(languageCode),
      );

      // Show green toast instead of blocking alert
      showToast(`Customer language changed to: ${languageName}`);

      // Apply it to any live session. The system prompt and voice are baked
      // into a Nova Sonic session at start and cannot be changed on the open
      // bidirectional stream, so the only way to honour the change is to
      // restart. Without this the toast claimed success while the session kept
      // translating into the previous language — until an unrelated restart
      // (up to 7.5 minutes later) silently adopted the new value mid-call.
      applyLanguageChangeToLiveSessions();
    },
  );
  /* CCP_V2V.UI.customerTranslateToLanguageSaveButton.addEventListener("click", () => {
    addUpdateLocalStorageKey("customerTranslateToLanguage", CCP_V2V.UI.customerTranslateToLanguageSelect.value);
  });
  CCP_V2V.UI.customerNovaSonicVoiceSaveButton.addEventListener("click", () => {
    addUpdateLocalStorageKey("customerNovaSonicVoiceId", CCP_V2V.UI.customerNovaSonicVoiceSelect.value);
  });
  CCP_V2V.UI.agentNovaSonicVoiceSaveButton.addEventListener("click", () => {
    addUpdateLocalStorageKey("agentNovaSonicVoiceId", CCP_V2V.UI.agentNovaSonicVoiceSelect.value);
  }); */

  CCP_V2V.UI.agentStartTranscriptionButton.addEventListener(
    "click",
    agentStartTranscription,
  );

  CCP_V2V.UI.agentStopTranscriptionButton.addEventListener(
    "click",
    agentStopTranscription,
  );

  CCP_V2V.UI.agentAudioFeedbackEnabledCheckbox.addEventListener(
    "change",
    (event) => {
      if (event.target.checked) {
        if (ToAgentAudioStreamManager != null)
          ToAgentAudioStreamManager.enableAudioFeedback(
            AUDIO_FEEDBACK_FILE_PATH,
          );
      } else {
        if (ToAgentAudioStreamManager != null)
          ToAgentAudioStreamManager.disableAudioFeedback();
      }
    },
  );

  CCP_V2V.UI.agentStreamMicCheckbox.addEventListener("change", (event) => {
    const selectedMic = CCP_V2V.UI.micSelect.value;
    const micConstraints = getMicrophoneConstraints(selectedMic);
    if (event.target.checked) {
      if (ToCustomerAudioStreamManager != null)
        ToCustomerAudioStreamManager.startMicrophone(micConstraints);
    } else {
      if (ToCustomerAudioStreamManager != null)
        ToCustomerAudioStreamManager.stopMicrophone();
    }
  });

  CCP_V2V.UI.agentStreamMicVolume.addEventListener("input", () => {
    // Mute-aware: moving the slider while muted must not reopen the raw mic.
    if (ToCustomerAudioStreamManager != null)
      ToCustomerAudioStreamManager.setMicrophoneVolume(getAgentRawMicVolume());
  });

  // fix 4: log every change to the popup settings, so call logs show which were on.
  logAudioSettingChanges();

  // Agent language dropdown — auto-save on change + toast notification
  CCP_V2V.UI.agentTranslateFromLanguageSelect.addEventListener("change", () => {
    const selectedOption =
      CCP_V2V.UI.agentTranslateFromLanguageSelect.options[
        CCP_V2V.UI.agentTranslateFromLanguageSelect.selectedIndex
      ];
    const languageName = selectedOption
      ? selectedOption.text
      : CCP_V2V.UI.agentTranslateFromLanguageSelect.value;
    const languageCode = CCP_V2V.UI.agentTranslateFromLanguageSelect.value;

    // Persist to localStorage — keeps the value in sync for the full app flow
    addUpdateLocalStorageKey("agentTranslateFromLanguage", languageCode);

    // Derive and persist the matching Nova Sonic voice ID for this language
    addUpdateLocalStorageKey("agentNovaSonicVoiceId", getVoiceId(languageCode));

    // Show green toast instead of blocking alert
    showToast(`Agent language changed to: ${languageName}`);

    // See the customer handler for why a restart is required here.
    applyLanguageChangeToLiveSessions();
  });
  //Translate Agent UI buttons
  /* CCP_V2V.UI.agentTranslateToLanguageSaveButton.addEventListener("click", () => {
    addUpdateLocalStorageKey("agentTranslateToLanguage", CCP_V2V.UI.agentTranslateToLanguageSelect.value);
  }); */
  CCP_V2V.UI.agentTranslateTextButton.addEventListener(
    "click",
    handleAgentTranslateText,
  );
  CCP_V2V.UI.agentTranslateTextInput.addEventListener("keypress", (e) => {
    if (e.key === "Enter") {
      handleAgentTranslateText();
    }
  });
};

const initCCP = async (onConnectInitialized) => {
  const { connectCCPURL } = getConnectURLS();
  if (!window.connect.core.initialized) {
    console.info(
      `${LOGGER_PREFIX} -  Amazon Connect CCP initialization started`,
    );
    window.connect.core.initCCP(CCP_V2V.UI.ccpContainer, {
      ccpUrl: connectCCPURL,
      loginPopup: true,
      loginPopupAutoClose: true,
      loginOptions: {
        // optional, if provided opens login in new window
        autoClose: true, // optional, defaults to `false`
        height: 600, // optional, defaults to 578
        width: 400, // optional, defaults to 433
        top: 0, // optional, defaults to 0
        left: 0, // optional, defaults to 0
      },
      region: CONNECT_CONFIG.connectInstanceRegion,
      softphone: {
        allowFramedSoftphone: false, //we don't want the default softphone
        allowFramedVideoCall: true, //allow the agent to add video to the call
        disableRingtone: false,
      },
      pageOptions: {
        enableAudioDeviceSettings: true,
        enableVideoDeviceSettings: true,
        enablePhoneTypeSettings: true,
      },
      shouldAddNamespaceToLogs: true,
    });

    window.connect.agent((agent) => {
      console.info(
        `${LOGGER_PREFIX} -  Amazon Connect CCP initialization completed`,
      );
      if (onConnectInitialized) onConnectInitialized(agent);
    });
  } else {
    console.info(`${LOGGER_PREFIX} - Amazon Connect CCP Already Initialized`);
  }
};

const onConnectInitialized = (connectAgent) => {
  connect = window.connect;
  SessionAgent = connectAgent;
  connect.core.initSoftphoneManager({ allowFramedSoftphone: true });

  const connectAgentConfiguration = connectAgent.getConfiguration();
  CurrentUser["currentUser_ConnectUsername"] =
    connectAgentConfiguration.username;

  subscribeToAgentEvents();
  subscribeToContactEvents();

  connect.core.onSoftphoneSessionInit(function ({ connectionId }) {
    ConnectSoftPhoneManager = connect.core.getSoftphoneManager();
    //console.info(`${LOGGER_PREFIX} - softphoneManager`, softphoneManager);
  });
};

function subscribeToAgentEvents() {
  // Subscribe to Agent Events from Streams API, and handle Agent events with functions defined above
  console.info(`${LOGGER_PREFIX} - subscribing to events for agent`);

  connect.agent((agent) => {
    agent.onLocalMediaStreamCreated(onAgentLocalMediaStreamCreated);
    agent.onMuteToggle(onAgentMuteToggle);
    // agent.onStateChange(agentStateChange);
    // agent.onRefresh(agentRefresh);
    // agent.onOffline(agentOffline);
  });
}

function subscribeToContactEvents() {
  // Subscribe to Contact Events from Streams API, and handle Contact events
  console.info(`${LOGGER_PREFIX} - subscribing to events for contact`);
  connect.contact((contact) => {
    console.info(`${LOGGER_PREFIX} - new contact`, contact);
    if (
      contact.getActiveInitialConnection() &&
      contact.getActiveInitialConnection().getEndpoint()
    ) {
      console.info(
        `${LOGGER_PREFIX} - new contact is from ${contact.getActiveInitialConnection().getEndpoint().phoneNumber}`,
      );
    } else {
      console.info(
        `${LOGGER_PREFIX} - this is an existing contact for this agent`,
      );
    }

    contact.onConnecting(onContactConnecting);
    contact.onConnected(onContactConnected);
    contact.onEnded(onContactEnded);
    contact.onDestroy(onContactDestroyed);
    // contact.onRefresh(contactRefreshed);
  });
}

function onContactConnecting(contact) {
  console.info(`${LOGGER_PREFIX} - contact is connecting`, contact);
  // Customer language is now set from the "Customer_Preferred_Language" CCP
  // contact attribute once the call is fully connected (onContactConnected →
  // populateCustomerInfo). Nothing to do here.
}

function onContactConnected(contact) {
  console.info(`${LOGGER_PREFIX} - contact connected`, contact);

  // populateCustomerInfo reads the "Customer_Preferred_Language" attribute
  // and sets the customer language dropdown BEFORE we inspect it below.
  populateCustomerInfo(contact);

  // Translation off (translationEnabled=false, or switched off since the page loaded): a plain call. Customer
  // Information above is filled as usual; no translation starts and the Start buttons stay disabled.
  if (!translationAllowed()) {
    console.info(`${LOGGER_PREFIX} - onContactConnected - translation not enabled; plain call`);
    return;
  }

  // Customer button is hidden (controlled by agent buttons) but keep it
  // internally enabled so customerStartTranscription() can run freely.
  CCP_V2V.UI.customerStartTranscriptionButton.disabled = false;

  // ══ REQ 2: Auto-start transcription on INBOUND calls when languages differ ══
  //
  // Rules:
  //  - INBOUND only: outbound calls always require a manual Start click.
  //  - Languages must differ: same-language calls need no translation.
  //  - agentStartTranscription() controls both sessions (Req 1 wiring).
  //  - If auto-start fails the Start button is re-enabled for manual use.
  const initiationMethod = contact.getInitiationMethod?.() ?? "UNKNOWN";
  const isInbound = initiationMethod?.toLowerCase() === "inbound";

  if (isInbound) {
    // Customer language was just set by populateCustomerInfo() above.
    const customerLang = CCP_V2V.UI.customerTranslateFromLanguageSelect.value;
    const agentLang    = CCP_V2V.UI.agentTranslateFromLanguageSelect.value;

    if (customerLang && agentLang && customerLang !== agentLang) {
      // Languages differ — start both sessions automatically.
      console.info(
        `${LOGGER_PREFIX} - onContactConnected - INBOUND: languages differ` +
        ` (customer: "${customerLang}", agent: "${agentLang}") — auto-starting transcription`,
      );
      showToast(
        `🔄 Auto-starting transcription — customer: ${customerLang} ↔ agent: ${agentLang}`,
        4000,
      );
      // agentStartTranscription is async; fire without top-level await so
      // the contact event handler returns immediately. The inner catch
      // re-enables the Start button if something goes wrong.
      agentStartTranscription().catch((e) => {
        console.error(
          `${LOGGER_PREFIX} - onContactConnected - auto-start failed`, e,
        );
        // Re-enable so the agent can try manually
        CCP_V2V.UI.agentStartTranscriptionButton.disabled = false;
      });
    } else {
      // Same language (or no language selected) — translation not required;
      // enable the Start button so the agent can opt in manually.
      console.info(
        `${LOGGER_PREFIX} - onContactConnected - INBOUND: languages match` +
        ` ("${customerLang}") — transcription not auto-started`,
      );
      CCP_V2V.UI.agentStartTranscriptionButton.disabled = false;
    }
  } else {
    // OUTBOUND call — enable Start button for manual use.
    console.info(
      `${LOGGER_PREFIX} - onContactConnected - OUTBOUND call, enabling manual Start`,
    );
    CCP_V2V.UI.agentStartTranscriptionButton.disabled = false;
  }
  // ═════════════════════════════════════════════════════════════════════════
}

async function onContactEnded(contact) {
  console.info(`${LOGGER_PREFIX} - contact has ended`, contact);
  CurrentAgentConnectionId = null;
  // Drop the pinned language pair so any restart still in flight sees a stale
  // contactId and aborts rather than attaching this call's configuration to
  // whatever call comes next.
  AgentSessionConfig = null;
  CustomerSessionConfig = null;
  if (ToCustomerAudioStreamManager != null) {
    ToCustomerAudioStreamManager.dispose();
    ToCustomerAudioStreamManager = null;
  }
  if (ToAgentAudioStreamManager != null) {
    ToAgentAudioStreamManager.dispose();
    ToAgentAudioStreamManager = null;
  }
  if (RTCSessionTrackManager != null) {
    RTCSessionTrackManager.dispose();
    RTCSessionTrackManager = null;
  }
  // Awaited so a failure in one teardown is visible here rather than becoming a
  // silent unhandled rejection, and so cleanUpUI() runs after both have settled.
  await customerStopTranscription().catch((e) =>
    console.error(`${LOGGER_PREFIX} - onContactEnded - customer teardown failed`, e),
  );
  await agentStopTranscription().catch((e) =>
    console.error(`${LOGGER_PREFIX} - onContactEnded - agent teardown failed`, e),
  );
  cleanUpUI();
}

function onContactDestroyed(contact) {
  console.info(`${LOGGER_PREFIX} - contact has been destroyed`, contact);

  // NOTE: the customer language is deliberately NOT reset here.
  //
  // It briefly was, to stop a new call inheriting the previous customer's
  // language. That made things worse: auto-detection only runs for INBOUND
  // calls with an ANI, so on an OUTBOUND call the reset value ("en") survived
  // and the session started as en->en — no translation at all, silently. It
  // also forced the agent to re-pick the language before every outbound call.
  //
  // The hazard the reset was aiming at (a stale or wrong language) is now
  // caught where it actually matters, by the source === target check in
  // captureSessionConfig().

  clearTranscriptCards();

  // If the sign-in session ended during this call, sign out now that it is over. Deferred a moment so the
  // agent's contact list no longer includes the destroyed contact.
  setTimeout(completePendingSignOut, 1000);

  // A version deployed during the call is offered now that the call is over.
  AppVersionWatch?.check();
}

async function onAgentLocalMediaStreamCreated(data) {
  console.info(
    `${LOGGER_PREFIX} - onAgentLocalMediaStreamCreated - WebRTC stream created/refreshed`,
  );
  const isRefresh = CurrentAgentConnectionId === data.connectionId;
  CurrentAgentConnectionId = data.connectionId;
  const session = ConnectSoftPhoneManager?.getSession(CurrentAgentConnectionId);
  const peerConnection = session?._pc;

  // fix 6: the agent side on the backup plays into the same output, so it is kept the same way.
  if ((AgentNovaSession || (TranslationActive && AgentFailover.state !== "nova")) && ToCustomerAudioStreamManager) {
    // ── Agent Nova Sonic session is ACTIVE ────────────────────────────────
    // Do NOT replace ToCustomerAudioStreamManager.
    // Nova Sonic is actively streaming Spanish audio into its Web Audio graph
    // (bufferSource → gainNode → mediaStreamDestination → audioTrack).
    // Disposing and recreating the manager here tears down that live graph
    // and causes packetsCount=0 (customer hears silence) even after the new
    // track is wired, because the audio pipeline to the destination is broken.
    //
    // Instead: only replace the RTC manager (new peer connection) and
    // immediately re-wire the EXISTING manager's live track to the new sender.
    console.info(
      `${LOGGER_PREFIX} - onAgentLocalMediaStreamCreated - agent session active,` +
        ` preserving ToCustomerAudioStreamManager, only replacing RTC manager`,
    );
    // fix 6: the customer-side backup waits for the new output instead of playing into the old one.
    customerOutputSwapping = true;
    try {
      await replaceToAgentAudioStreamManager();
    } finally {
      customerOutputSwapping = false;
    }
    // fix 4: the replaced manager starts without the agent's background noise; switch it back on.
    if (CCP_V2V.UI.agentAudioFeedbackEnabledCheckbox.checked === true) {
      ToAgentAudioStreamManager?.enableAudioFeedback(AUDIO_FEEDBACK_FILE_PATH);
    }
    await replaceRTCSessionTrackManager(peerConnection);
    const novaTrack = ToCustomerAudioStreamManager.getAudioTrack();
    await RTCSessionTrackManager?.replaceTrack(novaTrack, TrackType.POLLY);
    rtcTrackReplacedAt = Date.now(); // RCA-FIX: stamp track-swap time for RTC warm-up gate
    console.info(
      `${LOGGER_PREFIX} - onAgentLocalMediaStreamCreated - existing Nova Sonic track re-wired to new RTC sender`,
    );
  } else {
    // ── No active agent session ───────────────────────────────────────────
    // Safe to replace everything from scratch.
    await replaceToCustomerAudioStreamManager();
    await replaceToAgentAudioStreamManager();
    await replaceRTCSessionTrackManager(peerConnection);
    console.info(
      `${LOGGER_PREFIX} - onAgentLocalMediaStreamCreated - no active agent session, all managers replaced`,
    );
  }

  // If this is a MID-CALL WebRTC refresh (not initial connection) AND
  // customer Nova Sonic session is active, restart it with the fresh stream.
  // This is the root cause of "agent cannot hear customer after 8-min restart"
  // — the WebRTC peer connection refreshes asynchronously AFTER the Nova Sonic
  // restart, leaving the customer stream stale again.
  if (isRefresh && CustomerNovaSession && !customerSessionRestarting) {
    console.warn(
      `${LOGGER_PREFIX} - WebRTC refreshed mid-call — restarting customer Nova Sonic session with fresh stream`,
    );
    customerSessionRestarting = true;
    const staleCustomerSession = CustomerNovaSession;
    CustomerNovaSession = undefined;
    try {
      await Promise.resolve(staleCustomerSession.stop()).catch(() => {});
      // Small delay to let WebRTC stabilise before re-capturing
      await new Promise((resolve) => setTimeout(resolve, 800));
      if (CurrentAgentConnectionId) {
        // Only restart if call is still active
        const accumulated = { user: "", assistant: "", lastAssistant: "", lastSource: "" };
        await restartCustomerNovaSession(accumulated);
      }
    } finally {
      // Previously cleared before the restart ran, leaving the guard down for
      // its whole duration.
      customerSessionRestarting = false;
    }
  }

  // fix 6: the customer's level meter, and the customer's Transcribe while that side is not on Nova
  // Sonic, follow the refreshed stream.
  if (isRefresh && TranslationActive) {
    customerStartMonitoring().catch(() => {});
    if (CustomerFailover.state !== "nova") {
      customerRestartBackupTranscribe("WebRTC refresh").catch(() => {});
    }
  }

  // ── Agent channel: the refresh invalidates the mic MediaStream too ────────
  // AgentTranscribeAdapter holds a reference to the pre-refresh MediaStream.
  // After a refresh it keeps reading dead audio and never emits another final
  // transcript, so accumulated.user stays empty for the rest of the call. That
  // silently disarms the drift/refusal classifier AND strands the fallback with
  // no source text to translate — which is exactly how untranslated English
  // reached the customer in the reported calls (the logs show two
  // "session is idle … refreshing peer connection" events just before it).
  if (isRefresh && AgentNovaSession && !agentSessionRestarting) {
    console.warn(
      `${LOGGER_PREFIX} - WebRTC refreshed mid-call — restarting agent Nova Sonic session` +
      ` and Transcribe adapter with a fresh mic stream`,
    );
    agentSessionRestarting = true;
    const staleAgentSession = AgentNovaSession;
    AgentNovaSession = undefined;
    try {
      await Promise.resolve(staleAgentSession.stop()).catch(() => {});
      await new Promise((resolve) => setTimeout(resolve, 800));
      if (CurrentAgentConnectionId && !isStaleSessionConfig(AgentSessionConfig)) {
        // restartAgentNovaSession re-creates the MicWorkletStream and rebuilds
        // AgentTranscribeAdapter on top of it, which is what restores the
        // classifier's baseline.
        const accumulated = { user: "", assistant: "", lastAssistant: "", lastSource: "" };
        await restartAgentNovaSession(accumulated);
      }
    } finally {
      agentSessionRestarting = false;
    }
  }

  // fix 6: the agent side on the backup has no Nova Sonic session to restart: its microphone capture and
  // Transcribe are rebuilt instead (after the background restart running now, if one is).
  if (isRefresh && TranslationActive && AgentFailover.state !== "nova" && !AgentNovaSession) {
    if (agentSessionRestarting) AgentBackup.refreshPending = true;
    else await agentRebuildCapture("WebRTC refresh");
  }
}

function setAudioElementsSinkIds() {
  CCP_V2V.UI.fromCustomerAudioElement.setSinkId(CCP_V2V.UI.speakerSelect.value);
  CCP_V2V.UI.toCustomerAudioElement.setSinkId(CCP_V2V.UI.speakerSelect.value);
  CCP_V2V.UI.toAgentAudioElement.setSinkId(CCP_V2V.UI.speakerSelect.value);
}

//Instead of streaming Microphone, stream an Audio File
async function streamFile() {
  try {
    const fileStreamAudioTrack = RTCSessionTrackManager.createFileTrack(
      "./assets/speech_20241113001759828.mp3",
    );
    //console.info(`${LOGGER_PREFIX} - streamFile`, fileStreamAudioTrack);
    await RTCSessionTrackManager.replaceTrack(
      fileStreamAudioTrack,
      TrackType.FILE,
    );
  } catch (error) {
    console.error(`${LOGGER_PREFIX} - streamFile`, error);
    raiseError(`Error steaming file: ${error}`);
  }
}

//Instead of streaming File, stream Mic
async function streamMic() {
  const selectedMic = CCP_V2V.UI.micSelect.value;
  if (!selectedMic) {
    raiseError("Please select a microphone!");
    return;
  }

  const micConstraints = getMicrophoneConstraints(selectedMic);
  const micStreamAudioTrack =
    await RTCSessionTrackManager.createMicTrack(micConstraints);
  //console.info(`${LOGGER_PREFIX} - streamMic`, micStreamAudioTrack);
  await RTCSessionTrackManager.replaceTrack(micStreamAudioTrack, TrackType.MIC);
}

//Instead of removing AudioTrack, stream a silent AudioTrack
async function removeAudioTrack() {
  const silentTrack = RTCSessionTrackManager.createSilentTrack();
  // console.info(
  //   `${LOGGER_PREFIX} - removeAudioTrack - replacing with a silent track`
  // );
  await RTCSessionTrackManager.replaceTrack(silentTrack, TrackType.SILENT);
}

async function testMicrophone() {
  const selectedMic = CCP_V2V.UI.micSelect.value;

  if (!selectedMic) {
    raiseError("Please select a microphone!");
    return;
  }

  try {
    // Request access to the selected microphone
    const micConstraints = getMicrophoneConstraints(selectedMic);
    const micStream = await navigator.mediaDevices.getUserMedia(micConstraints);

    const volumeBar = document.getElementById("volumeBar");
    const agentMicTestManager = await getAgentMicTestManager();
    agentMicTestManager.startAudioTest(micStream, volumeBar);
  } catch (err) {
    console.error(
      `${LOGGER_PREFIX} - testMicrophone - Error accessing microphone`,
      err,
    );
    raiseError("Failed to access microphone.");
  }
}

async function stopTestMicrophone() {
  const agentMicTestManager = await getAgentMicTestManager();
  agentMicTestManager.stopAudioTest();
}

// Function to test the selected audio output device
function testAudioOutput() {
  const selectedSpeaker = CCP_V2V.UI.speakerSelect.value;
  if (!selectedSpeaker) {
    raiseError("Please select a speaker!");
    return;
  }

  // Create an audio context and set the output device using setSinkId()
  const audio = new Audio("/assets/chime-sound-7143.mp3");
  audio
    .setSinkId(selectedSpeaker)
    .then(() => {
      console.info(
        `${LOGGER_PREFIX} - testAudioOutput - Audio output device set successfully`,
      );
      audio
        .play()
        .then(() => {
          console.info(
            `${LOGGER_PREFIX} - testAudioOutput - Audio played successfully`,
          );
        })
        .catch((err) => {
          console.error(
            `${LOGGER_PREFIX} - testAudioOutput - Error playing audio:`,
            err,
          );
          raiseError("Failed to play audio.");
        });
    })
    .catch((err) => {
      console.error(
        `${LOGGER_PREFIX} - testAudioOutput - Error setting output device:`,
        err,
      );
      raiseError("Failed to set audio output device.");
    });
}

async function getDevices() {
  try {
    //check Microphone permission
    const micPermission = await navigator.permissions.query({
      name: "microphone",
    });
    if (micPermission.state === "prompt") {
      await navigator.mediaDevices.getUserMedia({ audio: true });
    }
    if (micPermission.state === "denied") {
      raiseError(
        "Microphone permission is denied. Please allow microphone access in your browser settings.",
      );
      return;
    }

    // Get all media devices (input and output)
    const devices = await navigator.mediaDevices.enumerateDevices();

    // Arrays to store cam, mic and speaker devices
    const micDevices = [];
    const speakerDevices = [];

    // Loop through devices and filter by kind
    devices.forEach((device) => {
      if (device.kind === "audioinput") {
        micDevices.push(device);
      } else if (device.kind === "audiooutput") {
        speakerDevices.push(device);
      }
    });

    //raise an error if we only found devices without deviceId
    if (micDevices.every((device) => !device.deviceId)) {
      raiseError(
        "No Microphone found. Please check your microphone and reload the page.",
      );
      return;
    }

    if (speakerDevices.every((device) => !device.deviceId)) {
      raiseError(
        "No Speaker found. Please check your speaker and reload the page.",
      );
      return;
    }

    // Populate the microphone dropdown
    CCP_V2V.UI.micSelect.innerHTML = "";
    micDevices.forEach((mic) => {
      const option = document.createElement("option");
      option.value = mic.deviceId;
      option.textContent = mic.label || `Microphone ${mic.deviceId}`;
      CCP_V2V.UI.micSelect.appendChild(option);
    });

    //pre-select the Default mic
    const defaultMic = micDevices.find((mic) =>
      mic.deviceId.startsWith("default"),
    );
    if (defaultMic) {
      CCP_V2V.UI.micSelect.value = defaultMic.deviceId;
    }
    //pre-select the saved mic
    const savedMicId = getLocalStorageValueByKey("selectedMicId");
    if (savedMicId) {
      CCP_V2V.UI.micSelect.value = savedMicId;
    }

    // Populate the speaker dropdown
    CCP_V2V.UI.speakerSelect.innerHTML = "";
    speakerDevices.forEach((speaker) => {
      const option = document.createElement("option");
      option.value = speaker.deviceId;
      option.textContent = speaker.label || `Speaker ${speaker.deviceId}`;
      CCP_V2V.UI.speakerSelect.appendChild(option);
    });

    //pre-select the Default speaker
    const defaultSpeaker = speakerDevices.find((speaker) =>
      speaker.deviceId.startsWith("default"),
    );
    if (defaultSpeaker) {
      CCP_V2V.UI.speakerSelect.value = defaultSpeaker.deviceId;
    }
    //pre-select the saved speaker
    const savedSpeakerId = getLocalStorageValueByKey("selectedSpeakerId");
    if (savedSpeakerId) {
      CCP_V2V.UI.speakerSelect.value = savedSpeakerId;
    }
  } catch (err) {
    console.error(
      `${LOGGER_PREFIX} - getDevices - Error accessing devices:`,
      err,
    );
  }
}

function loadNovaCustomerVoices() {
  // CCP_V2V.UI.customerNovaSonicVoiceSelect.innerHTML = "";
  /* NOVA_SONIC_VOICE_IDS.forEach((v) => {
    const option = document.createElement("option");
    option.value = v.id;
    option.textContent = v.label;
    // CCP_V2V.UI.customerNovaSonicVoiceSelect.appendChild(option);
  }); */

  // Derive voice ID from the saved customer language (or default to "matthew")
  // and persist it so the rest of the app always has a valid value on startup.
  const savedCustomerLang =
    getLocalStorageValueByKey("customerTranslateFromLanguage") || "en";
  addUpdateLocalStorageKey(
    "customerNovaSonicVoiceId",
    getVoiceId(savedCustomerLang),
  );
}

function loadNovaAgentVoices() {
  // CCP_V2V.UI.agentNovaSonicVoiceSelect.innerHTML = "";
  /* NOVA_SONIC_VOICE_IDS.forEach((v) => {
    const option = document.createElement("option");
    option.value = v.id;
    option.textContent = v.label;
    // CCP_V2V.UI.agentNovaSonicVoiceSelect.appendChild(option);
  }); */

  // Derive voice ID from the saved agent language (or default to "matthew")
  // and persist it so the rest of the app always has a valid value on startup.
  const savedAgentLang =
    getLocalStorageValueByKey("agentTranslateFromLanguage") || "en";
  addUpdateLocalStorageKey("agentNovaSonicVoiceId", getVoiceId(savedAgentLang));
}

// Creates Customer Speaker Stream used as input for Nova Sonic.
// Uses RemoteStreamWorkletStream (AudioWorkletNode) instead of
/**
 * Per-phase stopwatch for the Start button.
 *
 * Start is a chain of independent awaits — a getUserMedia, an AudioWorklet
 * module fetch, and two separate service stream handshakes — and which one
 * dominates depends on the headset, the network and whether it is the first
 * start of the page session. Without per-phase numbers, "Start takes about
 * five seconds" is not actionable. Every phase logs as [TIMING], so one call
 * in the console tells you where the time actually goes.
 */
function startPhaseTimer(label) {
  const t0 = performance.now();
  let last = t0;
  return {
    mark(phase) {
      const now = performance.now();
      console.info(
        `${LOGGER_PREFIX} - [TIMING] ${label} · ${phase}: ${Math.round(now - last)}ms`,
      );
      last = now;
    },
    total() {
      console.info(
        `${LOGGER_PREFIX} - [TIMING] ${label} · TOTAL: ${Math.round(performance.now() - t0)}ms`,
      );
    },
  };
}

// MicrophoneStream (ScriptProcessorNode) for consistent, jitter-free
// audio chunks on a dedicated audio thread — fixes:
//   - Audio level spikes (9000-13000) after session restart
//   - Agent unable to hear customer after restart
//   - Nova Sonic USER/ASSISTANT role misfires on customer stream
async function captureFromCustomerAudioStream() {
  const session = ConnectSoftPhoneManager?.getSession(CurrentAgentConnectionId);
  const audioStream = session?._remoteAudioStream;
  if (audioStream == null) {
    console.error(
      `${LOGGER_PREFIX} - captureFromCustomerAudioStream - No audio stream found from customer`,
    );
    throw new Error(
      "No audio stream found from customer, please check your browser sound settings",
    );
  }

  const audioCtx = await AudioContextMgr.getAudioContext();
  console.info(
    `${LOGGER_PREFIX} - captureFromCustomerAudioStream - creating RemoteStreamWorkletStream`,
  );
  return await RemoteStreamWorkletStream.create(audioCtx, audioStream);
}

/**
 * Restarts the Nova Sonic session for the customer stream.
 * Always destroys the old audio stream and re-captures a fresh one from
 * the current WebRTC audio element — critical because the WebRTC peer
 * connection may have been refreshed by Connect at the same time as the
 * session timeout, leaving the old stream stale/dead.
 */
async function restartCustomerNovaSession(accumulated) {
  // fix 6: set once the Nova Sonic session itself is being started, so only its failure hands the side
  // to the backup.
  let novaStartReached = false;
  try {
    console.info(
      `${LOGGER_PREFIX} - restartCustomerNovaSession - starting new session`,
    );

    // The call this restart was queued for may have ended during the backoff.
    if (isStaleSessionConfig(CustomerSessionConfig)) {
      console.warn(
        `${LOGGER_PREFIX} - restartCustomerNovaSession - aborting: session config belongs to` +
        ` contact "${CustomerSessionConfig?.contactId}" but current contact is` +
        ` "${CurrentAgentConnectionId}"`,
      );
      return false;
    }
    // fix 6: the backup builds later sessions from the same `accumulated`.
    CustomerBackup.accumulated = accumulated;

    // Defensive: never run two sessions against the same audio output.
    if (CustomerNovaSession) {
      const stale = CustomerNovaSession;
      CustomerNovaSession = undefined;
      await Promise.resolve(stale.stop()).catch(() => {});
    }

    // Step 1: Destroy old stale stream — never reuse after a WebRTC refresh
    if (AmazonTranscribeFromCustomerAudioStream) {
      try {
        AmazonTranscribeFromCustomerAudioStream.destroy?.();
        AmazonTranscribeFromCustomerAudioStream.stop?.();
      } catch {
        /* ignore cleanup errors */
      }
      AmazonTranscribeFromCustomerAudioStream = undefined;
    }

    // Step 2: Dispose + re-init ToAgentAudioStreamManager to clear buffered
    // audio from old session — prevents double audio feed causing level spikes.
    console.info(
      `${LOGGER_PREFIX} - restartCustomerNovaSession - resetting ToAgentAudioStreamManager`,
    );
    // fix 6: a backup sentence still playing to the agent finishes first (bounded), and the backup waits
    // for the new output instead of playing into the one being replaced.
    await Promise.race([
      CustomerBackupPlayback.catch(() => {}),
      new Promise((resolve) => setTimeout(resolve, 8000)),
    ]);
    customerOutputSwapping = true;
    try {
      if (ToAgentAudioStreamManager != null) {
        await ToAgentAudioStreamManager.dispose();
        ToAgentAudioStreamManager = null;
      }
      await replaceToAgentAudioStreamManager();
    } finally {
      customerOutputSwapping = false;
    }
    // fix 4: the replaced manager starts without the agent's background noise; switch it back on.
    if (CCP_V2V.UI.agentAudioFeedbackEnabledCheckbox.checked === true) {
      ToAgentAudioStreamManager?.enableAudioFeedback(AUDIO_FEEDBACK_FILE_PATH);
    }

    // Step 3: Re-capture fresh stream from current WebRTC audio element
    console.info(
      `${LOGGER_PREFIX} - restartCustomerNovaSession - re-capturing fresh audio stream`,
    );
    AmazonTranscribeFromCustomerAudioStream =
      await captureFromCustomerAudioStream();

    console.info("Starting interpretaion session.");
    console.info("Customer session language pair: ", CustomerSessionConfig);

    // Step 3: Start new Nova Sonic session with fresh stream, reusing the
    // language pinned for this call rather than re-reading the dropdowns.
    const customerStreamSampleRate = AudioContextMgr.getActualSampleRate();
    const guarded = guardNovaHandlers("customer", buildCustomerSessionHandlers(accumulated));
    novaStartReached = true;
    CustomerNovaSession = await startNovaSonicInterpreterSession({
      audioStream: AmazonTranscribeFromCustomerAudioStream,
      inputSampleRate: customerStreamSampleRate,
      sourceLangCode: CustomerSessionConfig.sourceLang,
      targetLangCode: CustomerSessionConfig.targetLang,
      voiceId: CustomerSessionConfig.voiceId,
      handlers: guarded.handlers,
      sessionLabel: "CUSTOMER-RESTART",
    });
    guarded.bind(CustomerNovaSession);
    console.info("Ending interpretaion session.");
    // Reset retry counter on successful restart
    customerRestartAttempts = 0;
    console.info(
      `${LOGGER_PREFIX} - restartCustomerNovaSession - new session started successfully`,
    );
    // fix 6: a side on the backup hands back to this session at the next quiet moment.
    CustomerFailover.novaSessionStarted();
    return true;
  } catch (err) {
    console.error(
      `${LOGGER_PREFIX} - restartCustomerNovaSession - failed`,
      err,
    );
    // fix 6: Nova Sonic did not start, so the customer side continues on the backup and Nova Sonic is
    // restarted in the background, instead of stopping with an alert.
    if (novaStartReached && TranslationActive && !isStaleSessionConfig(CustomerSessionConfig) && isBackupWorthy(err)) {
      customerAfterFailedRestart(err);
      return false;
    }
    raiseError(`Nova Sonic (customer) restart failed: ${err?.message || err}`);
    return false;
  }
}

/**
 * @param {{ startOnBackup?: { reason: string, cause: string } | null }} [options]
 *   fix 6: start this side on the backup (switch on, a recent Nova Sonic failure, or Nova Sonic did not
 *   start on the agent side).
 */
async function customerStartTranscription({ startOnBackup = null } = {}) {
  // Only agentStartTranscription() calls this, after its own translationAllowed() check. A switch-off that
  // arrives in between must not leave the agent side running without the customer side, so only the
  // environment's setting is checked here.
  if (!TRANSLATION_CONFIG.enabled) return;
  // Immediately hide Start and show the Loading button while the session initialises
  CCP_V2V.UI.customerStartTranscriptionButton.disabled = true;
  CCP_V2V.UI.customerStartTranscriptionButton.style.display = "none";
  CCP_V2V.UI.customerLoadingTranscriptionButton.style.display = "";

  const timer = startPhaseTimer("customerStart");
  try {
    if (CCP_V2V.UI.customerStreamMicCheckbox.checked === true) {
      //we want agent to hear the customer's original voice, so we reduce the fromCustomerAudioElement volume
      CCP_V2V.UI.fromCustomerAudioElement.volume = 0.3;
    } else {
      //we don't want agent to hear the customer's original voice, so we mute the fromCustomerAudioElement
      CCP_V2V.UI.fromCustomerAudioElement.muted = true;
    }

    //Play the audio feedback to customer
    if (CCP_V2V.UI.customerAudioFeedbackEnabledCheckbox.checked === true) {
      ToCustomerAudioStreamManager.enableAudioFeedback(
        AUDIO_FEEDBACK_FILE_PATH,
      );
    }

    //Get ready to stream To Customer
    // CRITICAL: must be awaited — same class of bug as restartAgentNovaSession.
    // Without await, audioSender.replaceTrack() fails silently as an unhandled
    // rejection and the RTC sender is never updated, causing packetsCount=0.
    const toCustomerAudioTrack = ToCustomerAudioStreamManager.getAudioTrack();
    await RTCSessionTrackManager.replaceTrack(toCustomerAudioTrack, TrackType.POLLY);
    timer.mark("replaceTrack");
    AmazonTranscribeFromCustomerAudioStream =
      await captureFromCustomerAudioStream();
    timer.mark("captureFromCustomerAudioStream");
    const customerStreamSampleRate = AudioContextMgr.getActualSampleRate();
    console.info(
      `${LOGGER_PREFIX} - customerStartTranscription - Nova Sonic customer stream sample rate: ${customerStreamSampleRate}`,
    );

    const accumulated = { user: "", assistant: "", lastAssistant: "", lastSource: "" };
    // Pin the language pair for this call. Note the direction: for the customer
    // channel the SOURCE is the customer and the TARGET is the agent, so the
    // voice must be the agent-language voice. It used to be derived from the
    // customer's language here — the exact inversion "FIX 1" identified on the
    // agent channel as a cause of Nova Sonic drifting back to the source.
    CustomerSessionConfig = captureSessionConfig(
      CCP_V2V.UI.customerTranslateFromLanguageSelect,
      CCP_V2V.UI.agentTranslateFromLanguageSelect,
    );
    console.info("Starting interpretaion session.");
    console.info("Customer session language pair: ", CustomerSessionConfig);
    // fix 6: the customer line's level meter (silence check), and the backup when this side starts on it.
    CustomerBackup.accumulated = accumulated;
    customerStartMonitoring().catch(() => {});
    if (startOnBackup && CustomerFailover.state === "nova") {
      CustomerFailover.startOnBackup(startOnBackup.reason, startOnBackup.cause);
    }
    if (CustomerFailover.state !== "nova") {
      // Nova Sonic is not started on this side, so its capture of the customer's stream is not needed.
      customerReleaseNovaCapture();
      customerStartBackupTranscribe();
    } else {
      const guarded = guardNovaHandlers("customer", buildCustomerSessionHandlers(accumulated));
      try {
        CustomerNovaSession = await startNovaSonicInterpreterSession({
          audioStream: AmazonTranscribeFromCustomerAudioStream,
          inputSampleRate: customerStreamSampleRate,
          sourceLangCode: CustomerSessionConfig.sourceLang,
          targetLangCode: CustomerSessionConfig.targetLang,
          voiceId: CustomerSessionConfig.voiceId,
          handlers: guarded.handlers,
          sessionLabel: "CUSTOMER",
        });
        guarded.bind(CustomerNovaSession);
        if (CustomerFailover.state !== "nova") {
          // The switch went on while the session was starting.
          customerAbandonNova();
          customerStartBackupTranscribe();
        }
      } catch (novaError) {
        if (!isBackupWorthy(novaError)) throw novaError;
        console.error(
          `${LOGGER_PREFIX} - customerStartTranscription - Nova Sonic did not start, the customer side starts on the backup`,
          novaError,
        );
        customerReleaseNovaCapture();
        novaUnhealthyUntil = Date.now() + NOVA_FAILURE_MEMORY_MS;
        CustomerFailover.startOnBackup(`Nova Sonic did not start: ${novaError?.message || novaError}`, "failure");
      }
    }
    timer.mark("Nova Sonic session open");
    timer.total();
    console.info("Ending customer interpretaion session.");
    // Customer language dropdown intentionally kept ENABLED during transcription
    // so the agent can correct the auto-detected or pre-selected language at any time.
    // (Both INBOUND and OUTBOUND calls keep the dropdown open for manual override.)
    // CCP_V2V.UI.customerTranslateToLanguageSelect.disabled = true;
    // CCP_V2V.UI.customerNovaSonicVoiceSelect.disabled = true;
    CCP_V2V.UI.customerStartTranscriptionButton.disabled = true;
    CCP_V2V.UI.customerStartTranscriptionButton.style.display = "none";
    CCP_V2V.UI.customerLoadingTranscriptionButton.style.display = "none";
    CCP_V2V.UI.customerStopTranscriptionButton.disabled = false;
    CCP_V2V.UI.customerStopTranscriptionButton.style.display = "";
  } catch (error) {
    // Session failed — restore Start button and hide Loading button
    CCP_V2V.UI.customerLoadingTranscriptionButton.style.display = "none";
    CCP_V2V.UI.customerStartTranscriptionButton.disabled = false;
    CCP_V2V.UI.customerStartTranscriptionButton.style.display = "";
    console.error(
      `${LOGGER_PREFIX} - customerStartTranscription - Error starting customer Nova Sonic session:`,
      error,
    );
    raiseError(`Error starting customer Nova Sonic session: ${error}`);
  }
}

/**
 * Builds the handler object for a Customer Nova Sonic session.
 * Extracted so both customerStartTranscription() and restartCustomerNovaSession()
 * share identical handler logic without duplication.
 */
function buildCustomerSessionHandlers(accumulated) {
  console.info("Acumulated customer:", accumulated);
  // Transcript text is assembled by CustomerTurn, not held here. `accumulated`
  // stays the classifier's and the fallback's view of the turn; the two are
  // deliberately separate, because accumulated.* is overwritten per fragment
  // while the transcript needs the whole utterance.
  //
  // The pendingUser / pendingAssistant snapshots that used to live here existed
  // to beat a 50ms setTimeout on the display writes. Those writes are
  // synchronous now, so the snapshots had nothing left to guard and were being
  // read while never being assigned.

  // ── fix 7: checks on what this session says to the agent ─────────────────
  // The same checks as the agent side (classifyNovaOutput: drift, refusal, assistant reply), judged
  // against what Nova Sonic heard the customer say. A turn fails from its first bad sentence on: that
  // sentence and the rest of the turn are neither played nor shown, and the agent hears Translate +
  // Polly of what Nova Sonic heard instead. Sentences that pass play exactly as before: Nova Sonic sends
  // each sentence's text before its audio, so the check is done before the first audio chunk arrives.
  //
  // The pair this session was started with: the customer's language is the source, the agent's the target.
  const langs = {
    sourceLang: CustomerSessionConfig?.sourceLang,
    targetLang: CustomerSessionConfig?.targetLang,
  };
  // With no pair, or the same language on both sides (nothing is translated), the output passes unchecked
  // as before: the fallback could not translate it anyway.
  const checksOn = !!(langs.sourceLang && langs.targetLang && langs.sourceLang !== langs.targetLang);
  // What Nova Sonic heard the customer say since its last answer began: [{ text, lang }].
  let heardPieces = [];
  let heardWaiters = [];
  // The answer Nova Sonic is giving: { heard, failed, verdict, fallback, fallbackDone, allowed, ended,
  // audioLogged }. Kept after its end, so late audio of a failed answer is still not played.
  let turn = null;
  // Held audio: chunks that arrived before their sentence was checked.
  let pendingAudio = [];
  let consecutiveBadTurns = 0;
  const judged = new JudgedSentences();
  // How long a failed answer's fallback waits for Nova Sonic's transcript when it had none yet.
  const HEARD_WAIT_MS = 1500;

  const heardText = (pieces) => pieces.map((p) => p.text).join(" ").trim();
  // The checks' baseline: what Nova Sonic heard, only when it is in the customer's language.
  const baselineOf = (t) => {
    const text = heardText(t.heard);
    return isUsableSourceBaseline(text, langs.sourceLang, langs.targetLang) ? text : "";
  };
  const openTurn = () => {
    turn = {
      heard: heardPieces,
      failed: false,
      verdict: null,
      fallback: null,
      fallbackDone: false,
      allowed: false,
      ended: false,
      audioLogged: false,
    };
    heardPieces = [];
  };
  const waitForHeard = (ms) =>
    new Promise((resolve) => {
      const done = () => {
        clearTimeout(timer);
        heardWaiters = heardWaiters.filter((w) => w !== done);
        resolve();
      };
      const timer = setTimeout(done, ms);
      heardWaiters.push(done);
    });

  /** The translation box, as before fix 7: shown unless it only repeats what was heard. */
  const showTranslation = (text) => {
    if (text && text.trim() !== accumulated.user.trim()) {
      // Set immediately so onTurnComplete reads the correct full sentence
      // even when completionEnd fires before the 50ms display timer.
      accumulated.assistant = text;
      accumulated.lastAssistant = text;
      // Nova Sonic sends this text once per generation stage (SPECULATIVE
      // then FINAL), usually identical; mergeTextChunk collapses the repeat
      // and joins a genuine continuation.
      CustomerTurn.pushTranslation(text);
    }
  };

  /** One chunk of Nova Sonic's translation to the agent (and to the customer, if that option is on). */
  async function playNovaAudio(wavBuf) {
    // Copy the buffer BEFORE any playback to prevent detached ArrayBuffer
    // errors when the same buffer is reused across multiple playAudioBuffer calls.
    const u8Primary = new Uint8Array(wavBuf.slice(0));
    const u8Feedback = new Uint8Array(wavBuf.slice(0));
    if (ToAgentAudioStreamManager != null) {
      await ToAgentAudioStreamManager.playAudioBuffer(u8Primary);
    }
    if (
      CCP_V2V.UI.customerStreamTranslationCheckbox.checked === true &&
      ToCustomerAudioStreamManager != null
    ) {
      await ToCustomerAudioStreamManager.playAudioBuffer(
        u8Feedback,
        CUSTOMER_TRANSLATION_TO_CUSTOMER_VOLUME,
      );
    }
  }

  /** Plays held chunks in order (playAudioBuffer decodes before queueing, so not in parallel). */
  function releaseHeldAudio() {
    const held = pendingAudio;
    pendingAudio = [];
    if (held.length === 0) return;
    (async () => {
      for (const chunk of held) {
        await playNovaAudio(chunk).catch(() => {});
      }
    })();
  }

  /**
   * The agent hears what Nova Sonic heard the customer say for this turn, instead of Nova Sonic's
   * output. Once per turn; resolves when it has been played (or could not be).
   */
  function speakTurnFallback(t, reason) {
    if (t.fallback) return t.fallback;
    t.fallback = (async () => {
      let text = heardText(t.heard);
      if (!text) {
        // Nova Sonic's transcript of the customer can arrive just after its answer starts.
        await waitForHeard(HEARD_WAIT_MS);
        text = heardText(heardPieces);
        if (text) {
          t.heard = heardPieces;
          heardPieces = [];
        }
      }
      if (!text) {
        CustomerCheckStats.inc("fallbackNoSource");
        console.error(
          `${LOGGER_PREFIX} - [CUSTOMER-FALLBACK] ${reason}, but Nova Sonic has no transcript of what the customer` +
          ` said — nothing to translate for this turn`,
        );
        return;
      }
      console.info(
        `${LOGGER_PREFIX} - [CUSTOMER-FALLBACK] ${reason}: the agent hears Translate + Polly of what Nova Sonic heard:` +
        ` "${text.slice(0, 80)}"`,
      );
      const speaker = customerCheckSpeaker();
      speaker.speakNow(text);
      await speaker.whenIdle();
    })().finally(() => {
      t.fallbackDone = true;
    });
    return t.fallback;
  }

  /** Restart the session so what it said leaves its context (the agent side's fix 4 rule). */
  function restartForContextHygiene(reason, session) {
    if (!TranslationActive || CustomerFailover.state !== "nova") return;
    if (!session || session !== CustomerNovaSession) {
      console.warn(`${LOGGER_PREFIX} - [CUSTOMER-CHECK] ${reason}, but that session has been replaced already — not restarting`);
      return;
    }
    if (customerSessionRestarting) {
      console.warn(`${LOGGER_PREFIX} - [CUSTOMER-CHECK] ${reason}, but a customer restart is already in progress — skipping`);
      return;
    }
    const sinceLast = Date.now() - lastCustomerHygieneRestartAt;
    if (sinceLast < CUSTOMER_HYGIENE_RESTART_COOLDOWN_MS) {
      console.warn(
        `${LOGGER_PREFIX} - [CUSTOMER-CHECK] ${reason}, but the customer session was restarted` +
        ` ${Math.round(sinceLast / 1000)}s ago — not restarting again yet`,
      );
      return;
    }
    lastCustomerHygieneRestartAt = Date.now();
    CustomerCheckStats.inc("restarts");
    console.warn(`${LOGGER_PREFIX} - [CUSTOMER-CHECK] ${reason} — restarting the customer session to clear its context`);
    customerSessionRestarting = true;
    consecutiveBadTurns = 0;
    accumulated.lastAssistant = "";
    CustomerNovaSession = undefined;
    Promise.resolve(session.stop())
      .catch(() => {})
      .finally(async () => {
        try {
          if (AmazonTranscribeFromCustomerAudioStream) {
            await restartCustomerNovaSession(accumulated);
          }
        } finally {
          customerSessionRestarting = false;
        }
      });
  }

  return {
    onUserText: (text) => {
      // Role-misfire suppression happens in the adapter (processResponseStream).
      // Note (fix 4): its contentName-keyed layers never fire, because Nova Sonic
      // output events carry contentId; the content-based layers do the work.
      accumulated.user = text;
      // fix 4: lets the agent session recognise the customer's voice picked up by the agent's mic.
      RecentCustomerSpeech.add(text);
      // fix 7: what Nova Sonic is going to answer, and the fallback's text if its answer fails.
      if (checksOn && text && text.trim()) {
        heardPieces.push({ text: text.trim(), lang: heardLanguage(text, langs.sourceLang, langs.targetLang, languageScore) });
        if (heardPieces.length > 12) heardPieces.shift();
        heardWaiters.slice().forEach((wake) => wake());
      }
      setBackgroundColour(
        CCP_V2V.UI.customerTranscriptionTextOutputDiv,
        "bg-pale-yellow",
      );
      // Merge rather than overwrite: Nova Sonic emits one utterance as several
      // textOutput events ("hola varios empleados reportaron correos
      // sospechosos" then "hoy"), so assigning each one left the box — and the
      // transcript bubble scraped from it — showing only the final fragment.
      CustomerTurn.pushOriginal(text);
      // updateLiveSentiment(CCP_V2V.UI.customerSentimentValue, text);
    },
    onUserTextRetraction: (misfiredTexts) => {
      // Layer 5 retraction — fires at completionEnd when adapter detects that
      // one or more USER texts emitted this turn were actually pre-ASSISTANT
      // misfires (translated text leaked under USER role before ASSISTANT block
      // opened).
      //
      // WHY WE ALWAYS CLEAR (not conditionally):
      //   Nova Sonic streams USER text in multiple small chunks. The speech
      //   box is updated with each chunk via onUserText, so by the time
      //   retraction fires the box shows only the LAST chunk — not the full
      //   misfired string. Comparing currentText === retractedText would
      //   only match the last chunk and miss the rest. Since Layer 5 only
      //   fires when the ENTIRE USER block for the turn is confirmed as a
      //   misfire, it is always safe to clear the box unconditionally.
      console.warn(
        `${LOGGER_PREFIX} - customer onUserTextRetraction | retracting ${misfiredTexts.length} misfire(s):`,
        misfiredTexts.map((t) => t.slice(0, 60)),
      );
      // Always clear — the full USER block this turn was a translation misfire.
      CustomerTurn.clearOriginal();
      setBackgroundColour(CCP_V2V.UI.customerTranscriptionTextOutputDiv);
      // Reset accumulated.user so the classifier baseline does not carry
      // misfire content into the next comparison.
      accumulated.user = "";
      // fix 7: a misfire is not what the customer said, so it is not a fallback's text either.
      const misfired = new Set(misfiredTexts.map((t) => String(t || "").trim()));
      heardPieces = heardPieces.filter((p) => !misfired.has(p.text));
      if (turn && !turn.ended) turn.heard = turn.heard.filter((p) => !misfired.has(p.text));
    },
    onAssistantText: (text, _partial, meta) => {
      if (!checksOn) {
        // Guard 2: Only update target box when translation differs from source.
        // Also track lastAssistant so onUserText can detect role misfires.
        showTranslation(text);
        return;
      }
      if (!text || !text.trim()) return;
      const isFinalCopy = meta?.stage === "FINAL";

      // fix 7: the second copy of a sentence already judged gets the first copy's verdict.
      if (isFinalCopy) {
        const prior = judged.find(text);
        if (prior) {
          if (prior.ok) showTranslation(text);
          return;
        }
        if (!turn || turn.ended) {
          // A FINAL copy with no first copy seen, after its answer ended: its audio has come and gone,
          // so it is only judged for the transcript.
          const late = classifyNovaOutput(text, "", langs, { taskTalk: (out) => customerMentionsTranslationTask(out, "") });
          judged.add(text, late === "OK");
          if (late === "OK") showTranslation(text);
          else console.warn(`${LOGGER_PREFIX} - [CUSTOMER-${late}] not shown to the agent: "${text.slice(0, 80)}"`);
          return;
        }
      }

      // A new answer takes what Nova Sonic heard since the last one. Nova Sonic hears the customer, then
      // answers, then ends its turn (or is interrupted); new words from the customer come after that. So
      // a sentence that follows new words from the customer starts a new answer even when the turn end
      // was missed (older builds had none), and a failed answer never mutes the next one.
      if (turn && !turn.ended && heardPieces.length > 0) turn.ended = true;
      if (!turn || turn.ended) openTurn();
      const t = turn;

      if (t.failed) {
        // The rest of a failed turn: not played, not shown, and no second fallback.
        judged.add(text, false);
        if (!isFinalCopy) {
          CustomerCheckStats.inc("mutedSentences");
          console.warn(`${LOGGER_PREFIX} - [CUSTOMER-CHECK] rest of a failed turn — not played to the agent: "${text.slice(0, 80)}"`);
        }
        return;
      }

      // The drift checks compare with what was heard only when it is in the customer's language (heard
      // already in the agent's language, a correct output would look like an echo of it). The refusal and
      // length checks need no such care, so they use whatever was heard: a short "mi contraseña es
      // hola123" is not a usable drift baseline, but Nova Sonic answering it with "I'm sorry, I can't help
      // with sharing passwords" is still a refusal.
      const baseline = baselineOf(t);
      const heardNow = heardText(t.heard);
      let verdict = classifyNovaOutput(text, baseline, langs, {
        currentSource: heardNow,
        taskTalk: (out) => customerMentionsTranslationTask(out, heardNow),
      });
      if (verdict === "OK" && !baseline && heardNow && matchesRefusalPattern(text) && !matchesRefusalPattern(heardNow)) {
        verdict = "REFUSAL";
      }
      // Nova Sonic saying back what it heard in the customer's language, too short for the language check
      // ("Hola, ¿me escucha?").
      if (
        verdict === "OK" &&
        heardNow &&
        heardLanguage(heardNow, langs.sourceLang, langs.targetLang, languageScore) === "source" &&
        (normalizeForCompare(text) === normalizeForCompare(heardNow) || isSameUtterance(text, heardNow))
      ) {
        verdict = "DRIFT";
      }
      if (!isFinalCopy) CustomerCheckStats.inc("sentences");

      if (verdict === "OK") {
        judged.add(text, true);
        if (!isFinalCopy) CustomerCheckStats.inc("ok");
        consecutiveBadTurns = 0;
        t.allowed = true;
        releaseHeldAudio();
        showTranslation(text);
        return;
      }

      // ── DRIFT, REFUSAL or ASSISTANT_REPLY ────────────────────────────────
      judged.add(text, false);
      t.failed = true;
      t.verdict = verdict;
      pendingAudio = [];
      consecutiveBadTurns++;
      CustomerCheckStats.inc(verdict === "DRIFT" ? "drift" : verdict === "REFUSAL" ? "refusal" : "assistantReply");
      console.warn(`${LOGGER_PREFIX} - [CUSTOMER-${verdict}] suppressing Nova Sonic output to the agent: "${text.slice(0, 80)}"`);
      const session = CustomerNovaSession;
      const fallbackDone = speakTurnFallback(t, verdict);
      (async () => {
        // Restart only after the fallback has played: the restart replaces the agent's audio output.
        await fallbackDone;
        // An assistant reply or thinking aloud stays in the session's context and repeats (the 2026-09-30
        // call: every later sentence), so it restarts at once. Drift and refusal get the agent side's
        // tolerance of three turns in a row; each bad turn is covered by the fallback meanwhile.
        let reason = null;
        if (verdict === "ASSISTANT_REPLY") reason = "assistant reply or thinking aloud instead of a translation";
        else if (consecutiveBadTurns >= 3) reason = `${consecutiveBadTurns} failed customer turns in a row`;
        if (reason) restartForContextHygiene(reason, session);
      })();
    },
    onAssistantAudioWav: async (wavBuf, meta) => {
      if (!checksOn) {
        await playNovaAudio(wavBuf);
        return;
      }
      const unvetted = meta && meta.vetted === false;
      // fix 7: audio of a failed turn is not played, including checked chunks arriving after its end (the
      // rest of its audio). An unchecked chunk after its end starts the next answer, handled below.
      if (turn?.failed && (!turn.ended || !unvetted)) {
        if (!turn.audioLogged) {
          turn.audioLogged = true;
          console.warn(`${LOGGER_PREFIX} - [CUSTOMER-CHECK] audio of a failed turn suppressed`);
        }
        return;
      }
      // Audio whose text has not been checked yet (`vetted: false`, or before the first sentence) is
      // held until its sentence passes, dropped if it fails, and replaced by the fallback if the turn
      // ends first. Nova Sonic sends each sentence's text first, so this does not delay good sentences.
      if (unvetted || !turn || !turn.allowed) {
        pendingAudio.push(wavBuf.slice(0));
        return;
      }
      // A checked chunk of an answer that passed plays, as before (also when it arrives after the turn end).
      await playNovaAudio(wavBuf);
    },
    onTurnComplete: (interrupted) => {
      // fix 7: audio that arrived but whose sentence was never checked is not played; the agent hears
      // the fallback for this turn instead.
      if (checksOn && pendingAudio.length > 0) {
        CustomerCheckStats.inc("uncheckedDiscarded", pendingAudio.length);
        console.warn(
          `${LOGGER_PREFIX} - [CUSTOMER-CHECK] turn ended with ${pendingAudio.length} unchecked audio chunk(s)` +
          ` — discarding and using the fallback translation`,
        );
        pendingAudio = [];
        // With no text at all for this answer, it is the answer to what was heard since the last one.
        if (!turn || turn.ended) openTurn();
        if (!turn.failed) {
          turn.failed = true;
          speakTurnFallback(turn, "unchecked audio");
        }
      }
      const fallbackPending = !!(turn && turn.fallback && !turn.fallbackDone);
      if (turn) turn.ended = true;
      // Close the turn through the accumulator rather than building a card
      // here. It already holds the merged original and translation for this
      // turn, so this is an early commit of what the settle timer would have
      // committed anyway — and commit() is idempotent, so the two paths cannot
      // produce duplicate bubbles.
      //
      // Building the card here instead used accumulated.user, which holds only
      // the LAST fragment of an utterance — the "hoy" bug — and committed a
      // second, truncated bubble alongside the accumulator's correct one.
      //
      // This handler fires from completionEnd, which is absent from every
      // captured log for this deployment. The accumulator's settle timer is
      // what actually closes turns today; this path is the correct-by-design
      // one for when completionEnd does arrive.
      if (interrupted) {
        console.warn(
          `${LOGGER_PREFIX} - customer onTurnComplete: interrupted — committing available content to transcript`,
        );
      }
      // fix 7: while the fallback for this turn is still coming, the turn stays open so its translation
      // joins the customer's words in one bubble (the accumulator's timer commits it afterwards).
      if (!fallbackPending) CustomerTurn.commit();
      accumulated.user = "";
      accumulated.assistant = "";
    },
    // fix 4: counted for the call summary only.
    onInterrupted: () => {
      CallStats.inc("customerInterruptions");
    },
    onSessionExpiring: () => {
      // Proactive restart — fires at 7m30s before AWS 8-min hard limit.
      // Seamlessly stop the current session and restart with same config.
      console.warn(
        `${LOGGER_PREFIX} - customer Nova Sonic session expiring — proactive restart`,
      );
      if (!customerSessionRestarting) {
        customerSessionRestarting = true;
        const expiringSession = CustomerNovaSession;
        CustomerNovaSession = undefined;
        Promise.resolve(expiringSession?.stop())
          .catch(() => {})
          .finally(async () => {
            try {
              if (AmazonTranscribeFromCustomerAudioStream) {
                // Session-only restart — audio stream stays alive, no gap in capture
                await restartCustomerNovaSession(accumulated);
              }
            } finally {
              // Held until the restart resolves, so a concurrent onError or a
              // WebRTC refresh cannot start a second overlapping restart.
              customerSessionRestarting = false;
            }
          });
      }
    },
    onError: (err) => {
      // Reactive safety net — handles unexpected drops (network, throttle, etc.)
      console.error(`${LOGGER_PREFIX} - customer Nova Sonic error`, err);
      if (customerSessionRestarting) {
        // Already restarting (proactive timer in progress) — skip double restart
        console.warn(
          `${LOGGER_PREFIX} - customer onError skipped — restart already in progress`,
        );
        return;
      }
      // fix 6: the backup takes over at once and Nova Sonic is restarted in the background (at most 3
      // attempts); once one works, Nova Sonic takes over again at the next quiet moment.
      if (TranslationActive && CustomerFailover.novaFailed(`Nova Sonic error: ${err?.message || err}`)) return;
      if (customerRestartAttempts >= MAX_RESTART_ATTEMPTS) {
        // Exceeded max retries — give up and surface error to agent
        console.error(
          `${LOGGER_PREFIX} - customer Nova Sonic — max restart attempts (${MAX_RESTART_ATTEMPTS}) reached, giving up`,
        );
        customerRestartAttempts = 0;
        raiseError(
          `Nova Sonic (customer) could not recover after ${MAX_RESTART_ATTEMPTS} attempts. Please stop and restart manually.`,
        );
        return;
      }
      customerRestartAttempts++;
      const backoffMs = customerRestartAttempts * 1500; // 1.5s, 3s, 4.5s
      console.warn(
        `${LOGGER_PREFIX} - customer Nova Sonic — reactive reconnect attempt ${customerRestartAttempts}/${MAX_RESTART_ATTEMPTS} in ${backoffMs}ms`,
      );
      customerSessionRestarting = true;
      // Stop the old session rather than just dropping the handle — otherwise
      // its response stream keeps iterating and keeps playing audio alongside
      // the replacement session.
      const previousSession = CustomerNovaSession;
      CustomerNovaSession = undefined;
      setTimeout(async () => {
        try {
          await Promise.resolve(previousSession?.stop()).catch(() => {});
          await restartCustomerNovaSession(accumulated);
        } finally {
          customerSessionRestarting = false;
        }
      }, backoffMs);
    },
  };
}

async function customerStopTranscription() {
  // Reset restart guard and retry counter on intentional stop.
  customerSessionRestarting = false;
  customerRestartAttempts = 0;
  // fix 6: the customer side's backup stops too: no more restarts, sentences or silence checks.
  if (CustomerFailover.state !== "nova") BackupStats.inc("customer", "backupMs", Date.now() - CustomerBackup.since);
  CustomerFailover.reset();
  CustomerVoiceWatch.stop();
  CustomerBackup.speaker?.cancel();
  // fix 7: a fallback sentence not yet played is dropped with the call.
  CustomerCheckSpeaker?.cancel();
  customerStopMonitoring();
  // Everything that can throw is isolated and the UI reset lives in `finally`.
  // This runs on every call teardown; if any step throws partway through, the
  // customer channel is left half-torn-down and the NEXT call cannot start.
  try {
    await customerStopBackupTranscribe().catch(() => {});
    if (CustomerNovaSession) {
      await CustomerNovaSession.stop().catch(() => {});
      CustomerNovaSession = undefined;
    }

    if (AmazonTranscribeFromCustomerAudioStream) {
      // RemoteStreamWorkletStream exposes ONLY destroy().
      //
      // This used to call setStream(silentStream) then stop() — MicrophoneStream
      // APIs that do not exist on the worklet-based stream. setStream threw
      // `TypeError: setStream is not a function`, which aborted the rest of this
      // function as an unhandled rejection. On every call teardown that left:
      //   • the worklet stream never destroyed and still running
      //   • AmazonTranscribeFromCustomerAudioStream still truthy
      //   • fromCustomerAudioElement still muted
      //   • the Start button hidden and Stop visible — so the agent could not
      //     start customer translation on the second call
      try {
        AmazonTranscribeFromCustomerAudioStream.destroy();
      } catch (e) {
        console.error(
          `${LOGGER_PREFIX} - customerStopTranscription - stream destroy failed`,
          e,
        );
      }
      AmazonTranscribeFromCustomerAudioStream = undefined;
    }
  } finally {
    CCP_V2V.UI.fromCustomerAudioElement.muted = false;

    // Dropdown was never disabled (kept always enabled for manual override),
    // so no re-enable needed here.
    CCP_V2V.UI.customerLoadingTranscriptionButton.style.display = "none";
    CCP_V2V.UI.customerStartTranscriptionButton.disabled = false;
    CCP_V2V.UI.customerStartTranscriptionButton.style.display = "";
    CCP_V2V.UI.customerStopTranscriptionButton.disabled = true;
    CCP_V2V.UI.customerStopTranscriptionButton.style.display = "none";
  }
}

/**
 * Shared Transcribe callbacks for the agent channel.
 *
 * accumulated.user is not just the "Agent said" display — it is the baseline
 * the drift/refusal classifier compares against AND the source text the
 * Translate+Polly fallback speaks. lastSource keeps the most recent value alive
 * across turn boundaries so the classifier is not blind between utterances.
 */
function buildAgentTranscriptHandler(accumulated) {
  // fix 4: one SourceUtterance per call, shared with the session handlers through `accumulated`. It
  // joins the segments of a sentence (assigning each FINAL kept only the last segment, so the checks
  // and the fallback saw only the end of a long sentence) and knows which sentence Nova Sonic is on.
  const source = (accumulated.source ??= new SourceUtterance());
  return (text) => {
    // fix 6: while the agent side is not on Nova Sonic, the sentence is translated by the backup.
    if (AgentFailover.routesToBackup()) {
      agentBackupSentence(text);
      return;
    }
    source.add(text);
    accumulated.user = source.current();
    accumulated.lastSource = accumulated.user;
    // Fetch the fallback translation now, while Nova Sonic is still translating, so it can play at
    // once if Nova Sonic's output fails a check.
    FallbackPrefetch.schedule(source.pendingText() || source.turnText());
    setBackgroundColour(CCP_V2V.UI.agentTranscriptionTextOutputDiv, "bg-pale-yellow");
    // Transcribe fires once per FINAL result, and a long sentence closes as
    // several finals, so assigning here dropped everything but the last
    // segment. Merging also absorbs the short spurious finals ("S", "The")
    // that room noise produces, instead of letting one blank out the box.
    AgentTurn.pushOriginal(text);
    updateLiveSentiment(CCP_V2V.UI.agentSentimentValue, text);
    // fix 6: a Nova Sonic session that reports nothing at all about this sentence has gone silent.
    AgentSilenceWatch.noteSentence(text, AgentNovaSession);
  };
}

/**
 * A dead Transcribe stream used to be a bare console.error. It silently
 * disables the classifier and strands the fallback with nothing to translate,
 * so the agent needs to know.
 */
function buildAgentTranscribeErrorHandler(phase) {
  return (err) => {
    console.error(`${LOGGER_PREFIX} - AgentTranscribeAdapter ${phase} error`, err);
    showToast(
      "Agent transcription stopped — translation safety checks are degraded. " +
      "Stop and restart translation if this persists.",
      8000,
    );
  };
}

/**
 * Restarts the Nova Sonic session for the agent stream.
 * Always destroys the old MicWorkletStream and re-creates a fresh one —
 * critical because the mic capture may have been affected by a WebRTC
 * connection refresh happening simultaneously with the session timeout.
 */
async function restartAgentNovaSession(accumulated) {
  // fix 6: set once the Nova Sonic session itself is being started, so only its failure hands the side
  // to the backup.
  let novaStartReached = false;
  try {
    console.info(
      `${LOGGER_PREFIX} - restartAgentNovaSession - starting new session`,
    );

    // The call this restart was queued for may have ended while we waited out
    // the backoff. Restarting now would attach a session configured for the
    // previous customer's language to whatever call is live.
    if (isStaleSessionConfig(AgentSessionConfig)) {
      console.warn(
        `${LOGGER_PREFIX} - restartAgentNovaSession - aborting: session config belongs to` +
        ` contact "${AgentSessionConfig?.contactId}" but current contact is` +
        ` "${CurrentAgentConnectionId}"`,
      );
      return false;
    }
    // fix 6: the backup builds later sessions and Transcribe handlers from the same `accumulated`.
    AgentBackup.accumulated = accumulated;

    // Defensive: never leave a previous session iterating its response stream
    // while a replacement starts. Callers are expected to have stopped it, but
    // two live sessions writing to the same audio output is the failure this
    // guards against.
    if (AgentNovaSession) {
      const stale = AgentNovaSession;
      AgentNovaSession = undefined;
      await Promise.resolve(stale.stop()).catch(() => {});
    }

    // Stop AgentTranscribeAdapter BEFORE destroying the old MicWorkletStream.
    // The adapter holds a ref to the old MediaStream - destroying it first
    // leaves the adapter feeding dead audio into Transcribe (hangs silently).
    if (AgentTranscribeAdapter) {
      await AgentTranscribeAdapter.stop().catch(() => {});
      AgentTranscribeAdapter = null;
    }

    // Step 1: Destroy old stale MicWorkletStream — never reuse after timeout
    // fix 6: the old session's view of it and the backup's reader of it end with it.
    AgentBackup.view?.close();
    AgentBackup.view = null;
    agentStopDrain();
    if (AmazonTranscribeToCustomerAudioStream) {
      try {
        AmazonTranscribeToCustomerAudioStream.destroy();
      } catch {
        /* ignore cleanup errors */
      }
      AmazonTranscribeToCustomerAudioStream = undefined;
    }

    // fix 4: let a fallback translation that is still playing finish first (bounded). Disposing the
    // manager underneath it cut the customer off mid-sentence after every drift restart.
    // fix 6: a backup sentence playing now is part of AgentFallbackPlayback too.
    await Promise.race([
      AgentFallbackPlayback.catch(() => {}),
      new Promise((resolve) => setTimeout(resolve, 8000)),
    ]);

    // Step 2: Dispose + re-init ToCustomerAudioStreamManager to clear buffered
    // audio from old session — prevents double audio feed causing level spikes.
    console.info(
      `${LOGGER_PREFIX} - restartAgentNovaSession - resetting ToCustomerAudioStreamManager`,
    );
    // fix 6: until the new output is wired (Step 4), the backup waits instead of playing into this one.
    agentOutputSwapping = true;
    if (ToCustomerAudioStreamManager != null) {
      await ToCustomerAudioStreamManager.dispose();
      ToCustomerAudioStreamManager = null;
    }
    await replaceToCustomerAudioStreamManager();

    // Step 3: Re-create fresh MicWorkletStream from current mic device
    console.info(
      `${LOGGER_PREFIX} - restartAgentNovaSession - re-creating fresh MicWorkletStream`,
    );
    const agentAudioCtx = await AudioContextMgr.getAudioContext();
    const selectedMic = CCP_V2V.UI.micSelect.value;
    const micConstraints = getMicrophoneConstraints(selectedMic);
    AmazonTranscribeToCustomerAudioStream = await MicWorkletStream.create(
      agentAudioCtx,
      micConstraints,
    );
    // The new track starts enabled — re-apply CCP mute before Transcribe or
    // Nova Sonic hears anything.
    applyAgentMuteState();

    // Restart AgentTranscribeAdapter with fresh MicWorkletStream after Step 3.
    AgentTranscribeAdapter = new TranscribeStreamAdapter({
      audioContext: agentAudioCtx,
      micMediaStream: AmazonTranscribeToCustomerAudioStream.getMediaStream(),
      languageCode:   AgentSessionConfig.sourceLang,
      region:         TRANSCRIBE_CONFIG.region,
      onTranscript:   buildAgentTranscriptHandler(accumulated),
      onError:        buildAgentTranscribeErrorHandler("restart"),
    });
    // Fire-and-forget: Nova Sonic must start without waiting for Transcribe HTTP
    // handshake. Awaiting start() causes MicWorkletStream to buffer 1-3s of audio
    // which Nova Sonic receives as a burst, triggering safety guardrail responses.
    AgentTranscribeAdapter.start().catch(function (err) {
      console.error(
        LOGGER_PREFIX + " - AgentTranscribeAdapter restart start failed",
        err,
      );
    });

    // Step 4: Wire Nova Sonic audio track to RTC BEFORE starting session.
    // The AudioStreamManager destination track is valid immediately on creation.
    // Wiring it now ensures no original mic audio leaks to customer between
    // manager creation and Nova Sonic session start.
    // CRITICAL: must be awaited — previously this was fire-and-forget, so the
    // async audioSender.replaceTrack() call inside could fail silently as an
    // unhandled rejection, leaving the RTC sender on the old stopped track and
    // producing packetsCount=0 (customer hears silence after restart).
    console.info(
      `${LOGGER_PREFIX} - restartAgentNovaSession - wiring audio track to RTC`,
    );
    const toCustomerAudioTrack = ToCustomerAudioStreamManager.getAudioTrack();
    await RTCSessionTrackManager?.replaceTrack(
      toCustomerAudioTrack,
      TrackType.POLLY,
    );
    rtcTrackReplacedAt = Date.now(); // RCA-FIX: stamp track-swap time for RTC warm-up gate
    agentOutputSwapping = false; // fix 6: the new output is wired

    // Step 5: Restore audio feedback and mic stream if they were enabled
    if (CCP_V2V.UI.agentAudioFeedbackEnabledCheckbox.checked === true) {
      ToAgentAudioStreamManager?.enableAudioFeedback(AUDIO_FEEDBACK_FILE_PATH);
    }
    // fix 4: ToCustomerAudioStreamManager was replaced above, so its background noise has to be
    // switched on again. Without it the customer's line went silent between sentences after every
    // restart (packetsCount 0 in the 2026-09-28 calls), clipping the start of each sentence; the same
    // happened for the rest of any call longer than the 7.5-minute session renewal.
    if (CCP_V2V.UI.customerAudioFeedbackEnabledCheckbox.checked === true) {
      ToCustomerAudioStreamManager?.enableAudioFeedback(AUDIO_FEEDBACK_FILE_PATH);
    }
    if (CCP_V2V.UI.agentStreamMicCheckbox.checked === true) {
      await ToCustomerAudioStreamManager.startMicrophone(micConstraints);
      ToCustomerAudioStreamManager.setMicrophoneVolume(getAgentRawMicVolume());
    }

    console.info("Starting agent interpretaion session.");
    console.info(
      "Selected Agent language:",
      CCP_V2V.UI.agentTranslateFromLanguageSelect.value,
    );
    // Step 6: Start new Nova Sonic session with fresh stream
    const agentStreamSampleRate = AudioContextMgr.getActualSampleRate();
    // Reuse the language pinned when the call's session first started, rather
    // than re-reading the dropdowns — a restart must not silently switch the
    // call to a different language pair.
    // fix 6: Nova Sonic reads the microphone through a view that does not destroy it when the session
    // ends, so the agent's Transcribe keeps hearing it if Nova Sonic has to be restarted again.
    const view = createNovaInputView(AmazonTranscribeToCustomerAudioStream);
    const guarded = guardNovaHandlers("agent", buildAgentSessionHandlers(accumulated));
    novaStartReached = true;
    try {
      AgentNovaSession = await startNovaSonicInterpreterSession({
        audioStream: view,
        inputSampleRate: agentStreamSampleRate,
        sourceLangCode: AgentSessionConfig.sourceLang,
        targetLangCode: AgentSessionConfig.targetLang,
        voiceId: AgentSessionConfig.voiceId,
        handlers: guarded.handlers,
        sessionLabel: "AGENT-RESTART",
      });
    } catch (startError) {
      view.close();
      throw startError;
    }
    guarded.bind(AgentNovaSession);
    AgentBackup.view = view;
    console.info("End agent transcriptionsession");
    // Reset retry counter on successful restart
    agentRestartAttempts = 0;
    console.info(
      `${LOGGER_PREFIX} - restartAgentNovaSession - new session started successfully`,
    );
    // fix 6: a side on the backup hands back to this session at the next quiet moment.
    AgentFailover.novaSessionStarted();
    return true;
  } catch (err) {
    agentOutputSwapping = false;
    console.error(`${LOGGER_PREFIX} - restartAgentNovaSession - failed`, err);
    // fix 6: Nova Sonic did not start, so the agent side continues on the backup and Nova Sonic is
    // restarted in the background, instead of stopping with an alert.
    if (novaStartReached && TranslationActive && !isStaleSessionConfig(AgentSessionConfig) && isBackupWorthy(err)) {
      agentAfterFailedRestart(err);
      return false;
    }
    raiseError(`Nova Sonic (agent) restart failed: ${err?.message || err}`);
    return false;
  }
}

// ─── Language identification ─────────────────────────────────────────────────
//
// Replaces the old English-only looksLikeEnglish() heuristic, which was
// hardcoded to English markers in a 22-language app and was disabled outright
// by "FIX 2" because it false-positived on the first turn of every session.
//
// The question we actually need answered is not "is this English?" but
// "is this in the language we asked Nova Sonic to speak?". That framing works
// for every language pair and needs no Transcribe baseline, which is what
// closes the window where untranslated audio reached the customer.

/**
 * Scripts that identify a language outright, held as CODE POINT ranges.
 *
 * Compiled with String.fromCodePoint() rather than written as literal
 * characters inside a regex literal. A regex literal containing literal
 * Devanagari or CJK is valid JavaScript, but only while the file stays UTF-8.
 * Copy it through anything that re-encodes -- a PowerShell
 * `Get-Content | Set-Content` without `-Encoding utf8`, an editor saving as
 * ANSI -- and the character class turns into mojibake whose endpoints are out
 * of order, which Rollup rejects at build time with
 * "Invalid regular expression: Range out of order in character class".
 * Keeping the source pure ASCII makes that failure impossible.
 */
const SCRIPT_RANGE_CODEPOINTS = {
  hi:      [[0x0900, 0x097f]],                    // Devanagari
  ar:      [[0x0600, 0x06ff]],                    // Arabic
  ru:      [[0x0400, 0x04ff]],                    // Cyrillic
  uk:      [[0x0400, 0x04ff]],                    // Cyrillic
  zh:      [[0x4e00, 0x9fff]],                    // Han
  "zh-TW": [[0x4e00, 0x9fff]],                    // Han
  ja:      [[0x3040, 0x30ff], [0x4e00, 0x9fff]],  // Kana + Han
  ko:      [[0xac00, 0xd7af], [0x1100, 0x11ff]],  // Hangul
};

/** Compile [[from, to], ...] code point ranges into a character-class regex. */
function buildRangeRegex(ranges) {
  const body = ranges
    .map(([from, to]) => String.fromCodePoint(from) + "-" + String.fromCodePoint(to))
    .join("");
  return new RegExp("[" + body + "]", "gu");
}

const LANGUAGE_SCRIPT_RANGES = Object.fromEntries(
  Object.entries(SCRIPT_RANGE_CODEPOINTS).map(([code, ranges]) => [
    code,
    buildRangeRegex(ranges),
  ])
);

/** Unicode combining marks, used to fold accents away before matching. */
const COMBINING_MARKS = buildRangeRegex([[0x0300, 0x036f]]);

/**
 * Strip diacritics so every pattern in this file can be written in plain
 * ASCII. A useful side effect: patterns then match whether or not the model
 * bothered to emit the accents.
 */
function foldAccents(text) {
  return text.normalize("NFD").replace(COMBINING_MARKS, "");
}

/**
 * Stopword sets for the Latin-script languages, where script tells us nothing.
 * Deliberately short and high-frequency: function words that appear in almost
 * any sentence of the language and almost never in the others.
 *
 * Written without accents because markerScore() folds them first.
 *
 * Caveat: Portuguese and Spanish share a lot of these ("que", "para", "como",
 * "esta"), so a pt<->es pair discriminates far more weakly than any other
 * combination. Script-based languages (ja, zh) never reach this table.
 */
const LANGUAGE_MARKERS = {
  // Enriched after a live call in which two drifted English outputs scored
  // 0.143 and 0.167 against the 0.18 floor in isWrongOutputLanguage() and so
  // were NOT flagged -- "Has someone clicked on the email link?" and "Is there
  // any sensitive information shared?" both reached the customer in English.
  // The only listed words they contained were 'the' and 'there'. Nova Sonic
  // drifts by PARAPHRASING in English, not by echoing, so the overlap check
  // does not save us either -- this list is the whole defence.
  //
  // Every addition is checked against the other eight languages: 'is' (nl),
  // 'was' (de/nl), 'also' (de) and 'over' (nl) are deliberately absent because
  // they are common words there too and would bias those pairs toward English.
  en: ['the','and','you','are','with','for','this','that','have','please','your','can','will','from','what','need','would','about','there','they',
       'has','had','been','being','does','did','doing','should','could','which','when','where','while','who','how','why',
       'them','their','these','those','then','because','before','after','again','any','some','such','only','into','just',
       'know','make','take','give','help','want','tell','send','check','much','many','here','were','but','all','more',
       'other','than','something','anything','someone','anyone','everything','thank','thanks','sorry'],
  nl: ['het','een','van','niet','met','voor','dat','die','zijn','hebben','deze','ook','maar','naar','worden','kunnen','alstublieft','wij','uw','nog'],
  fr: ['que','les','des','pour','avec','une','est','dans','pas','vous','nous','sur','plus','mais','votre','cette','nos','sont','etre','aussi'],
  de: ['der','die','das','und','ist','nicht','mit','fur','ein','eine','den','dem','sie','ich','wir','auf','von','haben','werden','bitte'],
  it: ['che','per','con','una','non','sono','nel','del','piu','come','questo','grazie','prego','della','suo','gli','anche','essere','molto','tutto'],
  pt: ['que','para','com','uma','nao','voce','mais','mas','como','esta','por','obrigado','favor','dos','seu','sao','isso','tambem','muito','pode'],
  // Additions avoid words Portuguese shares verbatim ('nada', 'algo', 'claro',
  // 'nunca', 'aqui'), since pt<->es is already the weakest pair in this table.
  es: ['que','los','las','por','para','con','una','del','esta','como','mas','pero','sus','necesito','puede','gracias','favor','tiene','esto','son',
       'estan','hacer','muy','ahora','cuando','donde','tambien','hasta','puedo','podria','quiero','disculpe','perdon',
       'entiendo','alguien','ningun','siempre',
       'hay','alguna','algun','otro','otra','mismo','solo','mejor','despues','aunque','mientras','segun',
       'entonces','tampoco','todavia','demasiado','nuestro','nuestra','ustedes','usted'],
};

/** Share of letter characters belonging to `scriptRegex`. */
function scriptRatio(text, scriptRegex) {
  const letters = text.replace(/[\s\d\p{P}\p{S}]/gu, "");
  if (letters.length === 0) return 0;
  const matches = text.match(scriptRegex);
  return (matches ? matches.length : 0) / letters.length;
}

/** Share of words that are known stopwords of `langCode`. */
function markerScore(text, langCode) {
  const markers = LANGUAGE_MARKERS[langCode];
  if (!markers) return 0;
  const words = foldAccents(text)
    .toLowerCase()
    .replace(/[^\p{L}\s]/gu, " ")
    .split(/\s+/)
    .filter(Boolean);
  if (words.length < 3) return 0;
  const set = new Set(markers);
  return words.filter((w) => set.has(w)).length / words.length;
}

/** Relative confidence that `text` is in `lang`: script share, else stopwords. */
function languageScore(text, lang) {
  const script = LANGUAGE_SCRIPT_RANGES[lang];
  return script ? scriptRatio(text, script) : markerScore(text, lang);
}

/**
 * Admission test for baseline source text.
 *
 * Deliberately stricter than isWrongOutputLanguage(), and asymmetric: rejecting
 * a good baseline costs one turn of reduced confidence, whereas ACCEPTING
 * target-language text poisons `accumulated.lastSource` — after which the
 * classifier compares against the wrong language and, worse, the Translate
 * fallback would try to translate the target language back into itself.
 *
 * isWrongOutputLanguage()'s 0.18 floor is too permissive here: a short Spanish
 * misfire like "¿alguien hizo clic en los enlaces de correo electrónico?"
 * scores only ~0.11 on Spanish stopwords and was admitted as English. Any lean
 * at all toward the target language now disqualifies the text.
 */
function isUsableSourceBaseline(text, sourceLang, targetLang) {
  const t = (text || "").trim();
  if (t.length < 8) return false;
  // fix 4: the source language must actually win. ">=" admitted a tie, and in the 2026-09-28 calls
  // five Spanish transcripts got in that way: "has" counts as English and "alguna" as Spanish (0.2 each),
  // and "okay déjame mirar este problema" scores 0 on both lists.
  const src = languageScore(t, sourceLang);
  return src > 0 && src > languageScore(t, targetLang);
}

/**
 * Tier 0 — is this output in the target language, or did Nova Sonic fall back
 * to the source language? Needs no Transcribe baseline, so it works on the
 * first turn of every session and throughout a Transcribe outage.
 *
 * @returns {boolean} true when the output is confidently NOT in targetLang
 */
function isWrongOutputLanguage(text, targetLang, sourceLang) {
  if (!text || text.trim().length < 12) return false; // too short to judge
  const trimmed = text.trim();

  // 1. Target uses a distinctive script (Hindi, Arabic, Cyrillic, CJK, Hangul).
  //    If almost none of it is present, this is not the target language.
  //    This is the check that catches the Hindi failures outright.
  const targetScript = LANGUAGE_SCRIPT_RANGES[targetLang];
  if (targetScript) {
    return scriptRatio(trimmed, targetScript) < 0.15;
  }

  // 2. Target is Latin-script but the source is not — if the output is in the
  //    source's script it is plainly an echo.
  const sourceScript = LANGUAGE_SCRIPT_RANGES[sourceLang];
  if (sourceScript && scriptRatio(trimmed, sourceScript) > 0.30) return true;

  // 3. Both Latin-script: compare stopword profiles. Require the source to win
  //    clearly (1.8x) and to clear an absolute floor, so shared cognates and
  //    proper nouns cannot trip it. This conservatism is deliberate — over-
  //    eager drift detection is what "FIX 2" and "FIX 5" were reacting to.
  const targetScore = markerScore(trimmed, targetLang);
  const sourceScore = markerScore(trimmed, sourceLang);
  if (sourceScore < 0.18) return false;
  return sourceScore > targetScore * 1.8;
}

// ─── Guardrail-refusal detection ─────────────────────────────────────────────
//
// Nova Sonic's safety alignment sometimes treats an utterance as a sensitive-
// data request ("share your employee ID and password") and answers as an
// assistant instead of translating: "Lo siento, pero no puedo solicitar
// información sensible… Esto violaría las políticas de seguridad y privacidad."
//
// Drift detection can never catch this: the refusal is in the TARGET language,
// so it looks like a perfectly good translation. It needs its own detector.
// ---- Guardrail-refusal detection -------------------------------------------
//
// Nova Sonic's safety alignment sometimes treats an utterance as a sensitive-
// data request ("share your employee ID and password") and answers as an
// assistant instead of translating: "Lo siento, pero no puedo solicitar
// informacion sensible... Esto violaria las politicas de seguridad."
//
// Drift detection can never catch this: the refusal is in the TARGET language,
// so it looks like a perfectly good translation. It needs its own detector.
//
// Patterns are ASCII-only and matched against accent-folded text, so they work
// on both "violaria" and "violaria" with the accent, and so this file carries
// no non-ASCII characters into a regex.
// fix 4: "responder/contestar" (and the other languages' "answer/respond") added. Call 3 on 2026-09-28
// had "Lo siento, pero no puedo responder a esta solicitud" pass as a translation.
const REFUSAL_PATTERNS = [
  /\b(lo siento|no puedo|no podria)\b[\s\S]{0,80}\b(proporcionar|solicitar|compartir|ayudar|dar|responder|contestar)\b/i,
  /\bi\s*(can'?t|cannot|can not|won'?t|am not able to)\b[\s\S]{0,80}\b(help|assist|provide|share|give|respond|answer)\b/i,
  /\b(violaria|viola|violate[sd]?|goes against|va en contra)\b[\s\S]{0,60}\b(politicas?|policy|policies|privacidad|privacy|seguridad|security)\b/i,
  /\b(as an ai|como (una |un )?(ia|asistente de ia)|i'?m an ai)\b/i,
  /\b(je ne peux pas|desole[e]?)\b[\s\S]{0,80}\b(fournir|partager|aider|donner|repondre)\b/i,
  /\b(es tut mir leid|ich kann nicht)\b[\s\S]{0,80}\b(bereitstellen|teilen|helfen|geben|antworten|beantworten)\b/i,
  /\b(mi dispiace|non posso)\b[\s\S]{0,80}\b(fornire|condividere|aiutare|dare|rispondere)\b/i,
  /\b(sinto muito|nao posso)\b[\s\S]{0,80}\b(fornecer|compartilhar|ajudar|dar|responder)\b/i,
  /\b(het spijt me|ik kan niet)\b[\s\S]{0,80}\b(verstrekken|delen|helpen|geven|antwoorden)\b/i,
];

function matchesRefusalPattern(text) {
  const t = foldAccents((text || "").trim());
  if (!t) return false;
  return REFUSAL_PATTERNS.some((re) => re.test(t));
}

/**
 * Classifies a Nova Sonic ASSISTANT output.
 *
 * @param {string} novaOutput   - ASSISTANT text from Nova Sonic
 * @param {string} baselineText - What the speaker actually said (source language)
 * @param {Object} langs        - { sourceLang, targetLang }
 * @param {Object} [opts]
 * @param {string} [opts.currentSource] - What the agent said in THIS sentence only (no carried-over
 *                                        text), for the length check. Empty when not known yet.
 * @param {Function} [opts.taskTalk]    - fix 7: the task-talk check to use (the customer side's
 *                                        customerMentionsTranslationTask); mentionsTranslationTask otherwise.
 * @returns {"OK"|"DRIFT"|"REFUSAL"|"ASSISTANT_REPLY"}
 */
function classifyNovaOutput(novaOutput, baselineText, { sourceLang, targetLang }, opts = {}) {
  const nova = (novaOutput || "").trim();
  if (!nova) return "OK";
  const baseline = (baselineText || "").trim();

  // ── DRIFT, Tier 0: wrong output language. No baseline needed. ─────────────
  if (isWrongOutputLanguage(nova, targetLang, sourceLang)) return "DRIFT";

  // ── ASSISTANT_REPLY: talk about the translation task (fix 4) ──────────────
  // Nova Sonic answering or commenting instead of translating, in the right language, so the check
  // above cannot see it. From call 3 on 2026-09-28: "Estoy listo para traducir… proporciona el texto
  // en inglés", "Estoy aquí para traducir, no para responder". Only counts when the agent's own words
  // say nothing of the kind; checked without a baseline too, because such a reply must never play.
  const taskTalk = opts.taskTalk || mentionsTranslationTask;
  if (taskTalk(nova, baseline)) return "ASSISTANT_REPLY";

  if (baseline) {
    // ── DRIFT, Tier 1: verbatim echo of the source. ─────────────────────────
    if (nova === baseline) return "DRIFT";

    // ── DRIFT, Tier 2: fuzzy word overlap with the source. ──────────────────
    // Threshold stays at 0.60 ("FIX 5") — cognates, numbers and proper nouns
    // legitimately survive translation, and a lower bar false-positived on
    // things like "Your case number is CASE-4892".
    const normalize = (s) => s.toLowerCase().replace(/[^\p{L}\p{N}\s]/gu, " ").trim();
    const meaningful = (words) => words.filter((w) => w.length > 3);
    const wordsA = meaningful(normalize(nova).split(/\s+/));
    const wordsB = meaningful(normalize(baseline).split(/\s+/));
    if (wordsA.length > 0 && wordsB.length > 0) {
      const setB = new Set(wordsB);
      const overlap = wordsA.filter((w) => setB.has(w)).length;
      if (overlap / Math.max(wordsA.length, wordsB.length) >= 0.60) return "DRIFT";
    }

    // ── REFUSAL ─────────────────────────────────────────────────────────────
    // Only meaningful with a baseline. An agent can legitimately say "I'm sorry,
    // but I can't share that information", whose correct translation matches
    // these same patterns. So it is a refusal only when the model produced
    // refusal language that the speaker did not — checked against the baseline
    // in its own language.
    if (matchesRefusalPattern(nova) && !matchesRefusalPattern(baseline)) {
      return "REFUSAL";
    }
  }

  // ── ASSISTANT_REPLY: far longer than what the agent said (fix 4) ───────────
  // The shape of an answer rather than a translation. Deliberately loose, and only against the
  // current sentence's text, never a carried-over one.
  if (opts.currentSource && isMuchLongerThan(nova, opts.currentSource)) return "ASSISTANT_REPLY";

  return "OK";
}

/**
 * Builds the handler object for an Agent Nova Sonic session.
 * Extracted so both agentStartTranscription() and restartAgentNovaSession()
 * share identical handler logic without duplication.
 */
function buildAgentSessionHandlers(accumulated) {
  console.info("Inside buildAgentSessionHandlers():", accumulated);

  // Language pair for this session. Captured once at session start rather than
  // read from the DOM per turn, so a mid-call dropdown change cannot make the
  // classifier judge output against a language the live session was never
  // configured for.
  const langs = {
    sourceLang: AgentSessionConfig?.sourceLang,
    targetLang: AgentSessionConfig?.targetLang,
  };

  // --- Bad-output state (scoped to this session's closure) ---
  // Counts consecutive turns where Nova Sonic failed to translate, either by
  // echoing the source language (DRIFT) or by answering as an assistant
  // instead of translating (REFUSAL).
  let consecutiveBadTurns = 0;

  // Per-turn audio decision. Nova Sonic normally emits ASSISTANT text before
  // the matching audio, so this is usually resolved before the first chunk
  // arrives and nothing is buffered. When audio arrives first we hold it
  // rather than gambling: playing unclassified audio is how untranslated
  // English reached the customer, and dropping it is how the customer got
  // silence. Buffering avoids both.
  const AUDIO_PENDING = "PENDING", AUDIO_ALLOW = "ALLOW", AUDIO_BLOCK = "BLOCK";
  let audioDecision = AUDIO_PENDING;
  let pendingAudio = [];
  // The baseline text the current audioDecision was made for.
  let decisionForBaseline = "";
  // Dedupe key for the fallback, and when it was set.
  //
  // This used to be a boolean reset in onTurnComplete. That made the fallback
  // depend on Nova Sonic sending completionEnd — and in practice it often does
  // not for the agent session (no [completionEnd] lines appear in the call
  // logs at all). The flag latched true after the FIRST fallback and silently
  // swallowed every later one, so only the first drifted utterance of a call
  // was ever rescued. Keying on the source text instead means the guard is
  // self-clearing: a new utterance is a new key. The timestamp lets a verbatim
  // repeat ("sorry, can you repeat that?") through after a short window.
  let lastFallbackSourceText = "";
  let lastFallbackAtMs = 0;
  const FALLBACK_DEDUPE_WINDOW_MS = 15000;
  // fix 4: the fallback that is playing for this session. A second request for the same sentence
  // (Nova Sonic sends each sentence twice, SPECULATIVE then FINAL) waits for it instead of returning
  // at once, so a restart triggered from the second copy no longer cuts the first one off.
  let fallbackPlayback = Promise.resolve();
  // A wait for Transcribe's text of the current sentence, shared by both copies of the sentence.
  let sourceWait = null;

  // fix 4: echo guard. Set when the adapter sees Nova Sonic transcribe its own previous output (it
  // heard the translation back through a speaker); the next output repeating the last played
  // sentence is then not played. Call 2b on 2026-09-28: the customer heard one sentence five times.
  let echoSuspected = false;
  let lastPlayedSentence = "";
  let sourceVersionAtLastPlayed = -1;
  let currentSentenceIsEcho = false;
  // fix 4: sentence counter, so both copies of a bad sentence ask for at most one restart.
  let sentenceSeq = 0;
  let restartRequestedForSentence = -1;

  // fix 4: what the agent said, sentence by sentence (see SourceUtterance). Shared with the
  // Transcribe handler through `accumulated`, and carried across restarts.
  const source = (accumulated.source ??= new SourceUtterance());
  const syncAccumulated = () => {
    accumulated.user = source.current() || source.provisional;
    accumulated.lastSource = source.last || accumulated.lastSource || "";
  };

  /**
   * Best available record of what the agent actually said, in their own
   * language: the sentence Nova Sonic is translating now, else Nova Sonic's
   * own ASR of it, else the previous sentence. This is the classifier's
   * baseline. The fallback uses only the current sentence (fallbackSourceText)
   * so it never speaks an earlier sentence again.
   */
  const getBaseline = () =>
    source.turnText() || source.provisional || source.last || accumulated.lastSource || "";
  const currentSentenceSource = () => source.turnText() || source.provisional;

  // fix 4: what Nova Sonic heard, sentence by sentence (see HeardUtterance). When it heard the agent
  // already in the customer's language, that sentence is what the customer gets if Nova Sonic's own
  // output fails.
  const heard = new HeardUtterance();
  // The hearing of each recent sentence, by its SPECULATIVE text, so its FINAL copy finds it.
  const heardBySentenceText = new Map();
  const heardForFinalCopy = (text) => {
    const key = normalizeForCompare(text);
    if (heardBySentenceText.has(key)) return heardBySentenceText.get(key);
    for (const [spec, record] of heardBySentenceText) {
      if (isSameUtterance(spec, key)) return record;
    }
    return null;
  };
  // Nothing new from the agent since the last sentence played: a repeat of it is Nova Sonic hearing
  // its own output (see the echo guard in onAssistantText).
  const nothingNewSinceLastPlayed = () => echoSuspected || source.version === sourceVersionAtLastPlayed;

  async function playToCustomer(u8) {
    if (ToCustomerAudioStreamManager != null) {
      // RCA-FIX: Gate Polly fallback audio until the WebRTC jitter buffer
      // has warmed up after a replaceTrack() call. Softphone metrics confirm
      // packetsCount=0 for ~1-2s after every track swap even when audioLevel
      // is non-zero -- audio renders locally but zero RTP packets reach the
      // customer phone during that cold-start window, causing silence.
      const warmupRemaining = (rtcTrackReplacedAt + RTC_WARMUP_MS) - Date.now();
      if (warmupRemaining > 0) {
        console.info(
          `[V2V][FALLBACK] RTC jitter buffer cold - delaying Polly by ${Math.ceil(warmupRemaining)}ms`,
        );
        await new Promise((resolve) => setTimeout(resolve, warmupRemaining));
      }
      await ToCustomerAudioStreamManager.playAudioBuffer(u8);
    }
  }

  /**
   * Deliver one chunk of translated audio to the customer AND, when the agent
   * has "stream translation to agent" enabled, to the agent's monitor.
   *
   * Both destinations belong together: the monitor is how the agent confirms
   * the customer is being spoken to. They had drifted apart — the direct path
   * in onAssistantAudioWav fed both, but the buffered-release path in
   * onAssistantText fed only the customer. So whenever a turn's audio arrived
   * before its classification and had to be held, the customer heard the
   * translation (late) while the agent heard nothing at all, which reads to
   * the agent exactly like the translation having been dropped.
   *
   * Each destination gets its own copy: playAudioBuffer hands the buffer to
   * decodeAudioData, which detaches it.
   */
  async function playTranslationAudio(u8) {
    // Take every copy BEFORE the first playback. playAudioBuffer hands its
    // array's buffer to decodeAudioData, which DETACHES it — so reading `u8`
    // again after awaiting the customer playback throws
    // "Cannot perform %TypedArray%.prototype.slice on a detached ArrayBuffer".
    // That is exactly what killed the Translate+Polly fallback: the customer
    // heard the Spanish, then this threw and the turn was logged as
    // "[FALLBACK] failed to deliver translation" with the agent monitor silent.
    const wantsMonitor =
      CCP_V2V.UI.agentStreamTranslationCheckbox.checked === true &&
      ToAgentAudioStreamManager != null;
    const forCustomer = new Uint8Array(u8);
    const forAgent = wantsMonitor ? new Uint8Array(u8) : null;

    await playToCustomer(forCustomer);
    if (forAgent) {
      await ToAgentAudioStreamManager.playAudioBuffer(
        forAgent,
        AGENT_TRANSLATION_TO_AGENT_VOLUME,
      );
    }
  }

  /**
   * The guarantee: when Nova Sonic fails, the customer still hears the
   * translation. Amazon Translate + Polly are deterministic and carry no
   * conversational guardrails, so this path cannot refuse.
   */
  //
  // Returns a promise that settles when the fallback for this sentence has finished playing, so the
  // caller can restart only after it (fix 4). The sentence's text is read synchronously, before the
  // caller closes the sentence.
  //
  // `hearing` is what Nova Sonic heard for this sentence (HeardUtterance.take()). When it heard the
  // agent already in the customer's language, that sentence is spoken as it is: no Translate step and
  // no wait for Transcribe, and usually prepared already. Translating the agent's own words is the
  // backup when it cannot be spoken.
  function speakFallbackTranslation(reason, hearing) {
    const checkedAt = Date.now();
    const sourceText = currentSentenceSource();
    if (hearing && hearing.usable && !hearing.echo) {
      hearing.covered = true;
      // Transcribe's text of the sentence, read now (or when it arrives) in case the backup is needed.
      const agentWords = sourceText
        ? Promise.resolve(sourceText)
        : source.waitForSegment(1500).then(() => currentSentenceSource());
      return startFallback(`heard:${hearing.text}`, { heardText: hearing.text, agentWords }, reason, checkedAt);
    }
    if (sourceText) return startFallback(sourceText, { sourceText }, reason, checkedAt);

    // Transcribe may not have closed the sentence yet. Wait briefly for it rather than speaking an
    // earlier sentence again, which is what falling back to lastSource used to do. Both copies of
    // the sentence share one wait.
    if (!sourceWait) {
      sourceWait = (async () => {
        await source.waitForSegment(1500);
        sourceWait = null;
        const late = currentSentenceSource();
        if (!late) {
          CallStats.inc("fallbackNoSource");
          console.error(
            `${LOGGER_PREFIX} - [FALLBACK] ${reason} but there is no source text for this sentence —` +
            ` cannot deliver a translation for it`
          );
          return;
        }
        return startFallback(late, { sourceText: late }, reason, checkedAt);
      })();
    }
    return sourceWait;
  }

  function startFallback(key, job, reason, checkedAt) {
    // Nova Sonic emits the same assistant text twice per turn (SPECULATIVE then
    // FINAL), so the same utterance classifies as bad twice. Speak it once, and
    // hand the second caller the playback already under way.
    const now = Date.now();
    if (
      key === lastFallbackSourceText &&
      now - lastFallbackAtMs < FALLBACK_DEDUPE_WINDOW_MS
    ) {
      console.info(
        `${LOGGER_PREFIX} - [FALLBACK] already spoken for this utterance — skipping duplicate`
      );
      return fallbackPlayback;
    }
    lastFallbackSourceText = key;
    lastFallbackAtMs = now;
    fallbackPlayback = deliverFallback(job, reason, checkedAt);
    AgentFallbackPlayback = fallbackPlayback;
    return fallbackPlayback;
  }

  /** What Nova Sonic heard, spoken as it is; null if that fails. */
  async function speakHeardText(text) {
    const prefetched = HeardSpeechPrefetch.take(text);
    let result = prefetched ? await prefetched : null;
    const usedPrefetch = !!(result && result.audio && result.audio.length);
    if (!usedPrefetch) {
      result = await synthesizeTargetSpeech({
        text,
        targetLangCode: langs.targetLang,
        translateRegion: TRANSLATE_CONFIG.region,
        pollyRegion: POLLY_CONFIG.region,
      }).catch(() => null);
    }
    return result && result.audio && result.audio.length ? { result, usedPrefetch } : null;
  }

  async function deliverFallback(job, reason, checkedAt) {
    try {
      let result = null;
      let usedPrefetch = false;
      let spokeHeard = false;
      let sourceText = job.sourceText;
      if (job.heardText) {
        const spoken = await speakHeardText(job.heardText);
        if (spoken) {
          ({ result, usedPrefetch } = spoken);
          spokeHeard = true;
        } else {
          sourceText = await job.agentWords;
          if (!sourceText) {
            CallStats.inc("fallbackNoSource");
            console.error(
              `${LOGGER_PREFIX} - [FALLBACK] ${reason}: could not speak what Nova Sonic heard, and there is` +
              ` no source text for this sentence — cannot deliver a translation for it`
            );
            return;
          }
          console.warn(
            `${LOGGER_PREFIX} - [FALLBACK] could not speak what Nova Sonic heard — translating the agent's words instead`
          );
        }
      }
      if (!result) {
        // fix 4: normally already fetched while Nova Sonic was still translating.
        const prefetched = FallbackPrefetch.take(sourceText);
        result = prefetched ? await prefetched : null;
        usedPrefetch = !!result;
        if (!result) {
          result = await synthesizeFallbackTranslation({
            sourceText,
            sourceLangCode: langs.sourceLang,
            targetLangCode: langs.targetLang,
            translateRegion: TRANSLATE_CONFIG.region,
            pollyRegion: POLLY_CONFIG.region,
          });
        }
      }
      if (!result) {
        CallStats.inc("fallbackFailed");
        return;
      }

      accumulated.assistant = result.text;
      accumulated.lastAssistant = result.text;
      // Replace, not merge: this translation supersedes the drifted or refused
      // Nova Sonic output for the turn rather than continuing it.
      AgentTurn.setTranslation(result.text);

      // Tier 3: the adapter translated the text but found no Polly voice for
      // the target language, so it returned audio:null by contract. The text
      // is already in the transcript above; there is nothing to play, and
      // handing decodeAudioData an empty buffer would surface as a misleading
      // "failed to deliver translation" error.
      if (!result.audio || result.audio.length === 0) {
        CallStats.inc("fallbackFailed");
        console.error(
          `${LOGGER_PREFIX} - [FALLBACK] translated text only, no audio available for` +
          ` "${langs.targetLang}" — the customer will not hear this turn`
        );
        return;
      }

      console.info(
        `${LOGGER_PREFIX} - [TIMING] fallback ${usedPrefetch ? "prefetched" : "fetched on demand"}` +
        ` | ready ${Date.now() - checkedAt}ms after the check`
      );
      lastPlayedSentence = result.text;
      sourceVersionAtLastPlayed = source.version;
      await playTranslationAudio(new Uint8Array(result.audio));
      CallStats.inc("fallbackPlayed");
      if (usedPrefetch) CallStats.inc("fallbackPrefetched");
      if (spokeHeard) CallStats.inc("heardSpoken");
      // fix 4: which text was spoken, where it came from, and in which voice.
      console.info(
        `${LOGGER_PREFIX} - [FALLBACK] delivered translation after ${reason}` +
        ` | ${spokeHeard ? "what Nova Sonic heard" : "Translate of the agent's words"}` +
        `${result.voiceLabel ? ` | ${result.voiceLabel}` : ""} | "${result.text.slice(0, 80)}"`
      );
    } catch (e) {
      CallStats.inc("fallbackFailed");
      console.error(`${LOGGER_PREFIX} - [FALLBACK] failed to deliver translation`, e);
    }
  }

  /** Restart the session so a refusal or persistent drift leaves the context. */
  function restartForContextHygiene(reason) {
    if (agentSessionRestarting) {
      // Worth logging: a stuck restart guard silently disables this recovery
      // path, and a silent return here is indistinguishable from "not needed".
      console.warn(
        `${LOGGER_PREFIX} - ${reason}, but a restart is already in progress — skipping`,
      );
      return;
    }
    // fix 4: rate-limited, so a session that keeps failing is not restarted in a loop. Each bad
    // sentence is still blocked and covered by the fallback meanwhile.
    const sinceLast = Date.now() - lastAgentHygieneRestartAt;
    if (sinceLast < AGENT_HYGIENE_RESTART_COOLDOWN_MS) {
      console.warn(
        `${LOGGER_PREFIX} - ${reason}, but the session was restarted ${Math.round(sinceLast / 1000)}s ago` +
        ` — not restarting again yet`,
      );
      return;
    }
    lastAgentHygieneRestartAt = Date.now();
    CallStats.inc("restarts");
    console.warn(`${LOGGER_PREFIX} - ${reason} — restarting agent session to clear context`);
    agentSessionRestarting = true;
    accumulated.lastAssistant = "";
    const previous = AgentNovaSession;
    AgentNovaSession = undefined;
    Promise.resolve(previous?.stop())
      .catch(() => {})
      .finally(async () => {
        consecutiveBadTurns = 0;
        try {
          if (AmazonTranscribeToCustomerAudioStream) {
            await restartAgentNovaSession(accumulated);
          }
        } finally {
          agentSessionRestarting = false;
        }
      });
  }

  return {
    // Nova Sonic's own ASR of the agent, used ONLY as a secondary baseline —
    // never displayed, so it cannot contaminate the agent's transcript box.
    //
    // This used to be `null`, which threw away the one source of agent speech
    // available before Transcribe delivers its FINAL result. That left the
    // classifier blind for the first (and often only) assistant text of each
    // turn. We accept it here but only when it is genuinely in the agent's
    // language — Nova Sonic frequently misfires and emits the TRANSLATION
    // under the USER role, which would poison the baseline with target-language
    // text and make every subsequent comparison meaningless.
    onUserText: (text) => {
      if (!text || !text.trim()) return;
      // fix 4: keep what Nova Sonic heard. Heard already in the customer's language, it is the text
      // the customer gets if Nova Sonic's own output fails, so it is made ready to speak now.
      const heardAs = heardLanguage(text, langs.sourceLang, langs.targetLang, languageScore);
      heard.add(text, heardAs);
      if (heardAs === "target") {
        console.info(
          `${LOGGER_PREFIX} - [HEARD] Nova Sonic heard the agent already in ${langs.targetLang}: "${text.slice(0, 80)}"`
        );
        if (heard.isUsable()) HeardSpeechPrefetch.schedule(heard.text());
        return; // never a baseline for the agent's own words
      }
      if (!isUsableSourceBaseline(text, langs.sourceLang, langs.targetLang)) {
        // Ignore it, and ONLY ignore it — do not treat it as a signal that the
        // session has inverted and needs restarting.
        //
        // Nova Sonic routinely mirrors the translation into the USER slot on a
        // perfectly healthy call. Replaying the accept/reject sequence of every
        // agent onUserText across the captured logs, a "two consecutive
        // rejections" rule would have fired 8, 3 and 4 times on calls that
        // produced ZERO drifted turns between them — one clean call ran
        // AAAARRRRRRRARR. Each firing is a full teardown: getUserMedia,
        // ToCustomerAudioStreamManager dispose, an outbound track swap and a
        // ~1.8s Bedrock reconnect, during which the agent speaks and nothing
        // reaches the customer. That is a far worse outcome than the condition
        // it was meant to catch.
        //
        // The fault worth acting on lives in the ASSISTANT slot, not this one:
        // the ASSISTANT output coming back in the SOURCE language. That is what
        // classifyNovaOutput detects and what the consecutiveBadTurns restart
        // already responds to. Rejecting the text here still does its real job
        // — keeping target-language text out of the classifier baseline.
        const why = text.trim().length < 8
          ? "too short to tell its language"
          : `not in the agent's language (${langs.sourceLang})`;
        console.warn(
          `${LOGGER_PREFIX} - [BASELINE] ignoring USER text, ${why}: "${text.slice(0, 60)}"`
        );
        return;
      }
      // fix 4: Nova Sonic's own ASR stands in only until Transcribe has the sentence.
      source.setProvisional(text);
      syncAccumulated();
    },
    onAssistantText: (text, _partial, meta) => {
      if (!text || !text.trim()) return;
      // fix 4: the adapter says which copy of the sentence this is. Counting and echo checks use the
      // SPECULATIVE copy (the first); the FINAL copy closes the sentence.
      const stage = meta?.stage;
      const isFinalCopy = stage === "FINAL";
      if (!isFinalCopy) sentenceSeq++;
      const thisSentence = sentenceSeq;
      source.beginTurn();

      // fix 4: the FINAL copy ends the sentence: later Transcribe segments belong to the next one.
      // Closed only once it has text, so a sentence Transcribe has not delivered yet can still take it.
      const closeSentence = () => {
        if (isFinalCopy && source.turnText()) source.endTurn();
        syncAccumulated();
      };

      // ── fix 4: what Nova Sonic heard for this sentence ────────────────────
      // A SPECULATIVE copy takes what was heard since the last sentence; its FINAL copy finds the same
      // hearing again. A text block with nothing new heard before it continues the last sentence heard.
      let hearing;
      if (!isFinalCopy) {
        hearing = heard.take();
        if (hearing) {
          if (heardFromCustomer(hearing, RecentCustomerSpeech.list())) hearing.echo = "customer";
          else if (isSameUtterance(hearing.text, lastPlayedSentence) && nothingNewSinceLastPlayed()) hearing.echo = "replay";
          heardBySentenceText.set(normalizeForCompare(text), hearing);
          while (heardBySentenceText.size > 8) heardBySentenceText.delete(heardBySentenceText.keys().next().value);
        }
      } else {
        hearing = heardForFinalCopy(text);
      }
      const continuing = hearing ? null : heard.continuing();

      // ── fix 4: echo guard ─────────────────────────────────────────────────
      // A new sentence that repeats the last one played, right after Nova Sonic was heard
      // transcribing that output (or with nothing new from the agent since), is Nova Sonic
      // translating its own voice. So is a sentence whose hearing was the customer's voice, picked up
      // by the agent's microphone, or the last sentence played heard back. Not played, not counted as
      // drift, no fallback.
      if (!isFinalCopy) {
        currentSentenceIsEcho =
          !!hearing?.echo || (isSameUtterance(text, lastPlayedSentence) && nothingNewSinceLastPlayed());
        echoSuspected = false;
      }
      if (currentSentenceIsEcho) {
        if (!isFinalCopy) CallStats.inc("echo");
        console.warn(
          hearing?.echo === "customer"
            ? `${LOGGER_PREFIX} - [ECHO] Nova Sonic heard the customer's own voice through the agent's microphone` +
              ` ("${hearing.text.slice(0, 60)}") — not played: "${text.slice(0, 80)}"`
            : `${LOGGER_PREFIX} - [ECHO] Nova Sonic repeated the sentence it just played, after hearing it back` +
              ` — not played: "${text.slice(0, 80)}"`
        );
        audioDecision = AUDIO_BLOCK;
        pendingAudio = [];
        decisionForBaseline = getBaseline();
        if (isFinalCopy) currentSentenceIsEcho = false;
        return;
      }

      // ── fix 4: sentence already spoken by the fallback ────────────────────
      // Its remaining text blocks (Nova Sonic often splits an answer in two) and its FINAL copy are
      // covered by what the customer already heard: not played, and no second fallback.
      if (hearing?.covered || continuing?.covered) {
        if (!isFinalCopy) {
          console.info(
            `${LOGGER_PREFIX} - [HEARD] already spoken to the customer — rest of Nova Sonic's output not played:` +
            ` "${text.slice(0, 80)}"`
          );
        }
        audioDecision = AUDIO_BLOCK;
        pendingAudio = [];
        decisionForBaseline = getBaseline();
        closeSentence();
        return;
      }

      // Classified synchronously: processResponseStream delivers textOutput
      // before the matching audioOutput, so the decision below is already in
      // place when the first audio chunk arrives.
      let verdict = classifyNovaOutput(text, getBaseline(), langs, {
        currentSource: currentSentenceSource(),
      });

      // fix 4: Nova Sonic heard the agent already in the customer's language, so the right output is
      // that sentence (prompt rule 10). An output made mostly of other words is an answer or a comment
      // (call 3 on 2026-09-28: every assistant reply followed such a hearing). The sentence heard is
      // spoken instead. A later block of the same sentence that adds such words is simply not played.
      const judgedBy = hearing || continuing;
      if (verdict === "OK" && judgedBy?.usable && !matchesHeard(text, `${judgedBy.text} ${judgedBy.previous}`)) {
        verdict = "MISMATCH";
      }

      // Remember which utterance this decision belongs to, so audio belonging
      // to a LATER utterance is not judged by it (see onAssistantAudioWav).
      decisionForBaseline = getBaseline();
      if (!isFinalCopy) CallStats.inc("agentSentences");

      if (verdict === "OK") {
        if (!isFinalCopy) CallStats.inc("novaOk");
        if (isFinalCopy) {
          lastPlayedSentence = text;
          sourceVersionAtLastPlayed = source.version;
        }
        consecutiveBadTurns = 0;
        audioDecision = AUDIO_ALLOW;
        // Release anything buffered while we were undecided. Sequentially:
        // playAudioBuffer awaits decodeAudioData before enqueuing, so firing
        // these in parallel would let chunks land in the queue out of order.
        const buffered = pendingAudio;
        pendingAudio = [];
        if (buffered.length > 0) {
          (async () => {
            for (const chunk of buffered) {
              await playTranslationAudio(chunk).catch(() => {});
            }
          })();
        }

        accumulated.assistant = text;
        accumulated.lastAssistant = text;
        AgentTurn.pushTranslation(text);
        closeSentence();
        return;
      }

      // ── DRIFT, REFUSAL, ASSISTANT_REPLY or MISMATCH ───────────────────────
      console.warn(
        verdict === "MISMATCH"
          ? `${LOGGER_PREFIX} - [MISMATCH] Nova Sonic said something other than what it heard` +
            ` ("${judgedBy.text.slice(0, 60)}") — suppressing: "${text.slice(0, 80)}"`
          : `${LOGGER_PREFIX} - [${verdict}] suppressing Nova Sonic output: "${text.slice(0, 80)}"`
      );
      // Set synchronously so audio chunks arriving during the async work below
      // are already blocked.
      audioDecision = AUDIO_BLOCK;
      pendingAudio = [];
      // fix 4: counted once per sentence. Counting both copies made "6 consecutive drifted turns"
      // mean 3 sentences. A mismatch is not counted towards a restart: the sentence it replaces is
      // the agent's own, heard correctly.
      if (!isFinalCopy) {
        if (verdict === "MISMATCH") {
          CallStats.inc("mismatch");
        } else {
          consecutiveBadTurns++;
          CallStats.inc(verdict === "DRIFT" ? "drift" : "refusal");
        }
      }

      // Extra words in a later block of a sentence whose own block played: nothing is missing.
      if (verdict === "MISMATCH" && !hearing) {
        closeSentence();
        return;
      }

      // The customer must not be left in silence — speak the real translation.
      // Started before the sentence is closed, so it reads this sentence's text.
      const fallbackDone = speakFallbackTranslation(verdict, hearing || continuing);
      closeSentence();

      (async () => {
        // Let the fallback finish playing before any restart: restartAgentNovaSession
        // disposes ToCustomerAudioStreamManager, which would tear down the audio
        // graph underneath it. playAudioBuffer resolves on bufferSource.onended, so
        // this covers actual playback. fix 4: the second copy of a sentence now waits
        // for the first copy's playback too, instead of restarting straight away.
        await fallbackDone;
        if (restartRequestedForSentence === thisSentence) return; // the other copy already asked

        // A refusal or assistant reply poisons the conversation context: once it is
        // in the session the model keeps doing it (call 3 on 2026-09-28: four in a
        // row). Restart immediately rather than waiting for a consecutive-failure
        // threshold. Drift gets a small tolerance first.
        let restartReason = null;
        if (verdict === "REFUSAL") restartReason = "guardrail refusal detected";
        else if (verdict === "ASSISTANT_REPLY") restartReason = "assistant reply instead of a translation";
        else if (verdict === "DRIFT" && consecutiveBadTurns >= 3) restartReason = `${consecutiveBadTurns} consecutive drifted sentences`;
        if (restartReason) {
          restartRequestedForSentence = thisSentence;
          restartForContextHygiene(restartReason);
        }
      })();
    },
    onAssistantAudioWav: async (wavBuf, meta) => {
      // Clear a stale BLOCK once the conversation has moved on.
      //
      // audioDecision is otherwise only reset in onTurnComplete, and Nova Sonic
      // never sends completionEnd for the agent session in this deployment, so
      // without this a single blocked turn would mute the customer for the
      // rest of the call.
      //
      // Deliberately limited to BLOCK. This used to re-arm on ANY decision
      // whose baseline had since changed, which quietly broke good turns: the
      // baseline is fed by Transcribe FINAL results, and when Nova Sonic's
      // assistant text beats Transcribe to the punch the decision is made
      // against the PREVIOUS baseline, then Transcribe lands and moves it. A
      // perfectly valid ALLOW was thrown away and the turn's audio buffered
      // until the next text event released it. In the captured call this
      // inversion happened on exactly one turn ("Thank you. Have a great
      // day.") and that was the one turn the agent could not hear.
      //
      // A stale ALLOW cannot leak a later turn's audio, because within an
      // assistant block Nova Sonic always sends the text before its audio, so
      // the next turn is classified before any of its audio arrives.
      if (audioDecision === AUDIO_BLOCK && getBaseline() !== decisionForBaseline) {
        audioDecision = AUDIO_PENDING;
        // fix 4: pendingAudio is kept. Under a BLOCK it can only hold audio still waiting for its own
        // text to be checked, and dropping it here lost that audio with no fallback.
      }

      const u8Primary = new Uint8Array(wavBuf.slice(0));

      // fix 4: `vetted: false` means no new preview text for THIS audio block went through the
      // classifier. Such audio is held whatever the previous sentence's decision was; before, an
      // earlier sentence's ALLOW played it unchecked (and an earlier BLOCK dropped it). Released when
      // its own text is classified OK (its FINAL copy follows the audio), dropped if that text fails,
      // and replaced by the fallback if the turn ends first. Ordinary sentences always send their
      // preview text first, so this adds no delay.
      const unvetted = meta && meta.vetted === false;

      if (audioDecision === AUDIO_BLOCK && !unvetted) {
        console.warn(`${LOGGER_PREFIX} - audio chunk suppressed (turn failed classification)`);
        return;
      }

      if (audioDecision === AUDIO_PENDING || unvetted) {
        // No ASSISTANT text has reached the classifier yet for this audio.
        // Hold it until onAssistantText decides, or until onTurnComplete gives up on it.
        if (unvetted) CallStats.inc("uncheckedHeld");
        pendingAudio.push(u8Primary);
        return;
      }

      await playTranslationAudio(u8Primary);
    },
    onTurnComplete: (interrupted) => {
      // fix 4: now called at the end of each assistant turn (the adapter reads contentEnd.stopReason).
      // Before, it waited for completionEnd, which Nova Sonic sends only when the session ends.
      // Early commit of the turn the accumulator is already holding — see the
      // customer channel's onTurnComplete for why this is not the primary
      // commit path and why committing twice is safe.
      if (interrupted) {
        console.warn(
          `${LOGGER_PREFIX} - agent onTurnComplete: interrupted — committing available content to transcript`,
        );
      }
      AgentTurn.commit();

      // Audio arrived but its text never passed the classifier, so it was
      // never language-checked. Discard it and speak the real translation
      // instead — this is the path that used to play untranslated English.
      if (pendingAudio.length > 0) {
        CallStats.inc("uncheckedDiscarded", pendingAudio.length);
        console.warn(
          `${LOGGER_PREFIX} - turn ended with ${pendingAudio.length} unchecked audio chunk(s)` +
          ` — discarding and using the fallback translation`,
        );
        speakFallbackTranslation("unchecked audio");
      }

      // Reset per-turn gating. Previously driftMode persisted across turns and
      // was only ever cleared by a clean onAssistantText, so a single bad turn
      // followed by a text-less one muted the customer for the rest of the call.
      audioDecision = AUDIO_PENDING;
      pendingAudio = [];

      // The sentence is over: later Transcribe segments belong to the next one.
      if (source.turnText()) source.endTurn();
      syncAccumulated();
      accumulated.assistant = "";
      // Nova Sonic's answer to the last hearing is complete: nothing later continues it.
      heard.endTurn();
    },
    // fix 4: counted for the call summary. Not acted on: in an interpreter an interruption means the
    // agent kept talking, and the customer still needs the translation already made.
    onInterrupted: () => {
      CallStats.inc("agentInterruptions");
    },
    // fix 4: Nova Sonic transcribed its own previous output (see the echo guard in onAssistantText).
    onEchoDetected: () => {
      echoSuspected = true;
    },
    onSessionExpiring: () => {
      // Proactive restart — fires at 7m30s before AWS 8-min hard limit.
      console.warn(
        `${LOGGER_PREFIX} - agent Nova Sonic session expiring — proactive restart`,
      );
      if (!agentSessionRestarting) {
        agentSessionRestarting = true;
        // If the session was failing classification when it expired, clear the
        // corrupted lastAssistant so the new session starts with clean context.
        if (consecutiveBadTurns > 0) {
          console.warn(
            `${LOGGER_PREFIX} - onSessionExpiring: clearing lastAssistant (badTurns=${consecutiveBadTurns})`,
          );
          accumulated.lastAssistant = "";
          consecutiveBadTurns = 0;
        }
        const expiringSession = AgentNovaSession;
        AgentNovaSession = undefined;
        Promise.resolve(expiringSession?.stop())
          .catch(() => {})
          .finally(async () => {
            try {
              if (AmazonTranscribeToCustomerAudioStream) {
                await restartAgentNovaSession(accumulated);
              }
            } finally {
              // Held until the restart resolves — see onError for why.
              agentSessionRestarting = false;
            }
          });
      }
    },
    onError: (err) => {
      // Reactive safety net — handles unexpected drops (network, throttle, etc.)
      console.error(`${LOGGER_PREFIX} - agent Nova Sonic error`, err);
      if (agentSessionRestarting) {
        // Already restarting (proactive timer in progress) — skip double restart
        console.warn(
          `${LOGGER_PREFIX} - agent onError skipped — restart already in progress`,
        );
        return;
      }
      // fix 6: the backup takes over at once (starting with what the agent said that Nova Sonic had not
      // translated) and Nova Sonic is restarted in the background (at most 3 attempts); once one works,
      // Nova Sonic takes over again at the next quiet moment.
      if (TranslationActive && AgentFailover.novaFailed(`Nova Sonic error: ${err?.message || err}`)) {
        accumulated.lastAssistant = "";
        consecutiveBadTurns = 0;
        return;
      }
      if (agentRestartAttempts >= MAX_RESTART_ATTEMPTS) {
        // Exceeded max retries — give up and surface error to agent
        console.error(
          `${LOGGER_PREFIX} - agent Nova Sonic — max restart attempts (${MAX_RESTART_ATTEMPTS}) reached, giving up`,
        );
        agentRestartAttempts = 0;
        raiseError(
          `Nova Sonic (agent) could not recover after ${MAX_RESTART_ATTEMPTS} attempts. Please stop and restart manually.`,
        );
        return;
      }
      // If the session was failing classification when the error fired, clear
      // the corrupted context so the restart does not carry it forward.
      if (consecutiveBadTurns > 0) {
        console.warn(
          `${LOGGER_PREFIX} - onError: clearing lastAssistant (badTurns=${consecutiveBadTurns})`,
        );
        accumulated.lastAssistant = "";
        consecutiveBadTurns = 0;
      }
      agentRestartAttempts++;
      const backoffMs = agentRestartAttempts * 1500; // 1.5s, 3s, 4.5s
      console.warn(
        `${LOGGER_PREFIX} - agent Nova Sonic — reactive reconnect attempt ${agentRestartAttempts}/${MAX_RESTART_ATTEMPTS} in ${backoffMs}ms`,
      );
      agentSessionRestarting = true;
      // Stop the old session rather than just dropping the handle. Dropping it
      // left sessionState.stopped false, so its response stream kept iterating
      // and kept pushing audio into ToCustomerAudioStreamManager while the
      // replacement session started — two sessions on one output, the second
      // with a fresh (empty) classification state.
      const previousSession = AgentNovaSession;
      AgentNovaSession = undefined;
      setTimeout(async () => {
        try {
          await Promise.resolve(previousSession?.stop()).catch(() => {});
          await restartAgentNovaSession(accumulated);
        } finally {
          // Held until the restart actually resolves. Clearing it first (as
          // before) left the guard down for the whole restart, so a concurrent
          // onError or WebRTC refresh could start a second overlapping restart.
          agentSessionRestarting = false;
        }
      }, backoffMs);
    },
  };
}

async function agentStartTranscription() {
  if (!checkTranslationAllowed("agentStartTranscription")) return;
  // Immediately hide Start and show the Loading button while the session initialises
  CCP_V2V.UI.agentStartTranscriptionButton.disabled = true;
  CCP_V2V.UI.agentStartTranscriptionButton.style.display = "none";
  CCP_V2V.UI.agentLoadingTranscriptionButton.style.display = "";

  const timer = startPhaseTimer("agentStart");
  try {
    const selectedMic = CCP_V2V.UI.micSelect.value;
    const micConstraints = getMicrophoneConstraints(selectedMic);

    // Pin the language pair for this call. Everything downstream — the session,
    // its restarts, Transcribe, the classifier and the fallback — reads from
    // here rather than from the live dropdowns.
    AgentSessionConfig = captureSessionConfig(
      CCP_V2V.UI.agentTranslateFromLanguageSelect,
      CCP_V2V.UI.customerTranslateFromLanguageSelect,
    );

    // fix 4: a fresh count for this call, and the settings it starts with.
    CallStats.reset();
    FallbackPrefetch.clear();
    HeardSpeechPrefetch.clear();
    lastAgentHygieneRestartAt = 0;
    // fix 7: the same for the customer side's checks.
    resetCustomerChecksForCall();
    console.info(`${LOGGER_PREFIX} - [SETTINGS] at start: ${describeAudioSettings()}`);

    if (CCP_V2V.UI.agentAudioFeedbackEnabledCheckbox.checked === true) {
      ToAgentAudioStreamManager.enableAudioFeedback(AUDIO_FEEDBACK_FILE_PATH);
    }

    // CRITICAL: must be awaited — same class of bug as restartAgentNovaSession.
    const toCustomerAudioTrack = ToCustomerAudioStreamManager.getAudioTrack();
    await RTCSessionTrackManager.replaceTrack(toCustomerAudioTrack, TrackType.POLLY);
    timer.mark("replaceTrack");

    if (CCP_V2V.UI.agentStreamMicCheckbox.checked === true) {
      await ToCustomerAudioStreamManager.startMicrophone(micConstraints);
      ToCustomerAudioStreamManager.setMicrophoneVolume(getAgentRawMicVolume());
      timer.mark("startMicrophone (2nd getUserMedia)");
    }

    // Use MicWorkletStream (AudioWorkletNode) instead of MicrophoneStream
    // (ScriptProcessorNode) for consistent, jitter-free audio chunks on a
    // dedicated audio thread — fixing Nova Sonic USER/ASSISTANT role misfires.
    const agentAudioCtx = await AudioContextMgr.getAudioContext();
    timer.mark("getAudioContext");
    AmazonTranscribeToCustomerAudioStream = await MicWorkletStream.create(
      agentAudioCtx,
      micConstraints,
    );
    timer.mark("MicWorkletStream.create (getUserMedia + addModule)");
    // The agent may already be muted in the CCP when Start is pressed.
    applyAgentMuteState();
    const agentStreamSampleRate = AudioContextMgr.getActualSampleRate();
    console.info(
      `${LOGGER_PREFIX} - agentStartTranscription - Nova Sonic agent stream sample rate (AudioWorklet): ${agentStreamSampleRate}`,
    );

    console.info("Starting agent interpretaion session.");
    console.info(
      "Selected Agent language:",
      CCP_V2V.UI.agentTranslateFromLanguageSelect.value,
    );
    const accumulated = { user: "", assistant: "", lastAssistant: "", lastSource: "" };
    // fix 6: this call's backup state. A call that starts on the backup (switch on, or Nova Sonic failed
    // on a recent call) is switched before Transcribe starts, so every sentence reaches the backup.
    resetBackupForCall();
    TranslationActive = true;
    AgentBackup.accumulated = accumulated;
    const startOnBackup = backupAtStart();
    if (startOnBackup) AgentFailover.startOnBackup(startOnBackup.reason, startOnBackup.cause);
    // Start AWS Transcribe Streaming for reliable agent-side transcription.
    // Transcribe always outputs the agent's source language — no context
    // contamination possible. The adapter creates its own AudioWorkletNode
    // on the same MediaStream as Nova Sonic (no second getUserMedia needed).
    AgentTranscribeAdapter = new TranscribeStreamAdapter({
      audioContext: agentAudioCtx,
      micMediaStream: AmazonTranscribeToCustomerAudioStream.getMediaStream(),
      languageCode:   AgentSessionConfig.sourceLang,
      region:         TRANSCRIBE_CONFIG.region,
      onTranscript:   buildAgentTranscriptHandler(accumulated),
      onError:        buildAgentTranscribeErrorHandler("start")
    });

    // Open both service streams together. Transcribe and Nova Sonic each cost
    // a full handshake — credentials, TLS reuse, then the service's own stream
    // setup — and neither depends on the other; both only need the mic stream
    // that already exists above. Awaiting them in series made Start wait for
    // the sum; this makes it wait for the slower of the two.
    //
    // .catch() is attached at creation, not awaited later, so that a throw from
    // the Nova Sonic start below cannot turn this into an unhandled rejection.
    const transcribeStarted = AgentTranscribeAdapter.start().catch((e) =>
      buildAgentTranscribeErrorHandler("start")(e),
    );

    // fix 6: Nova Sonic reads the microphone through a view that does not destroy it when the session
    // ends, so the agent's Transcribe keeps hearing it while Nova Sonic is restarted. If Nova Sonic does
    // not start, the agent side starts on the backup instead of failing Start.
    let agentNovaError = null;
    if (AgentFailover.state === "nova") {
      const view = createNovaInputView(AmazonTranscribeToCustomerAudioStream);
      const guarded = guardNovaHandlers("agent", buildAgentSessionHandlers(accumulated));
      try {
        AgentNovaSession = await startNovaSonicInterpreterSession({
          audioStream: view,
          inputSampleRate: agentStreamSampleRate,
          sourceLangCode: AgentSessionConfig.sourceLang,
          targetLangCode: AgentSessionConfig.targetLang,
          voiceId: AgentSessionConfig.voiceId,
          handlers: guarded.handlers,
          sessionLabel: "AGENT",
        });
        guarded.bind(AgentNovaSession);
        AgentBackup.view = view;
        // The switch went on while the session was starting.
        if (AgentFailover.state !== "nova") agentAbandonNova();
      } catch (novaError) {
        view.close();
        if (!isBackupWorthy(novaError)) throw novaError;
        agentNovaError = novaError;
        console.error(
          `${LOGGER_PREFIX} - agentStartTranscription - Nova Sonic did not start, the agent side starts on the backup`,
          novaError,
        );
        novaUnhealthyUntil = Date.now() + NOVA_FAILURE_MEMORY_MS;
        AgentFailover.startOnBackup(`Nova Sonic did not start: ${novaError?.message || novaError}`, "failure", {
          speakInProgress: true,
        });
      }
    }
    timer.mark("Nova Sonic session open");
    await transcribeStarted;
    timer.mark("Transcribe stream open (overlapped)");
    console.info("End agent sesions");
    // Agent language dropdown intentionally kept ENABLED during transcription
    // so the agent can change their language at any time for both INBOUND and OUTBOUND calls.
    // CCP_V2V.UI.agentTranslateToLanguageSelect.disabled = true;
    // CCP_V2V.UI.agentNovaSonicVoiceSelect.disabled = true;
    CCP_V2V.UI.agentStartTranscriptionButton.disabled = true;
    CCP_V2V.UI.agentStartTranscriptionButton.style.display = "none";
    CCP_V2V.UI.agentLoadingTranscriptionButton.style.display = "none";
    CCP_V2V.UI.agentStopTranscriptionButton.disabled = false;
    CCP_V2V.UI.agentStopTranscriptionButton.style.display = "";

    disableMicrophoneAndSpeakerSelection();

    // ── REQ 1: Agent Start also triggers Customer transcription ─────────────
    // The customer Start/Stop buttons are hidden; this is the single entry
    // point that controls both sessions together.
    // .catch() is attached so a customer-session failure does NOT propagate
    // into the agent catch block — the agent session stays alive.
    console.info(
      `${LOGGER_PREFIX} - agentStartTranscription - also starting customer transcription (Req 1)`,
    );
    // fix 6: the customer side starts on the backup too when the agent side did (switch, a recent
    // failure, or Nova Sonic not starting just now); it tries Nova Sonic in the background.
    const customerStartOnBackup =
      startOnBackup || (agentNovaError ? { reason: "Nova Sonic did not start on the agent side", cause: "failure" } : null);
    await customerStartTranscription({ startOnBackup: customerStartOnBackup }).catch((e) =>
      console.error(
        `${LOGGER_PREFIX} - agentStartTranscription - customer transcription start failed`, e,
      ),
    );
    // ────────────────────────────────────────────────────────────────────────

    timer.total();
  } catch (error) {
    // fix 6: nothing this Start opened keeps running. Each failed Start used to leave its Transcribe
    // stream and microphone capture open (and a retried Start overwrote the only handles to them).
    TranslationActive = false;
    stopBackupForCall();
    if (AgentNovaSession) {
      const session = AgentNovaSession;
      AgentNovaSession = undefined;
      Promise.resolve().then(() => session.stop()).catch(() => {});
    }
    if (AgentTranscribeAdapter) {
      const adapter = AgentTranscribeAdapter;
      AgentTranscribeAdapter = null;
      adapter.stop().catch(() => {});
    }
    if (AmazonTranscribeToCustomerAudioStream) {
      try {
        AmazonTranscribeToCustomerAudioStream.destroy();
      } catch {
        /* ignore cleanup errors */
      }
      AmazonTranscribeToCustomerAudioStream = undefined;
    }
    // Session failed — restore Start button and hide Loading button
    CCP_V2V.UI.agentLoadingTranscriptionButton.style.display = "none";
    CCP_V2V.UI.agentStartTranscriptionButton.disabled = false;
    CCP_V2V.UI.agentStartTranscriptionButton.style.display = "";
    console.error(
      `${LOGGER_PREFIX} - agentStartTranscription - Error starting agent Nova Sonic session:`,
      error,
    );
    raiseError(`Error starting agent Nova Sonic session: ${error}`);
  }
}

async function agentStopTranscription() {
  // fix 4: one summary line per call. agentStopTranscription can run twice for a call (Stop, then
  // contact end), so it prints only when something was counted, then resets.
  if (CallStats.hasActivity()) {
    console.info(`${LOGGER_PREFIX} - [CALL-SUMMARY] ${CallStats.summary()}`);
  }
  CallStats.reset();
  // fix 7: the customer side's checks, one line per call, printed the same way.
  if (CustomerCheckStats.hasActivity()) {
    console.info(`${LOGGER_PREFIX} - [CUSTOMER-CHECK-SUMMARY] ${CustomerCheckStats.summary()}`);
  }
  CustomerCheckStats.reset();
  FallbackPrefetch.clear();
  HeardSpeechPrefetch.clear();
  RecentCustomerSpeech.clear();
  // fix 6: the backup stops with the call: no more restarts, sentences or silence checks.
  TranslationActive = false;
  stopBackupForCall();

  // Reset restart guard and retry counter on intentional stop.
  agentSessionRestarting = false;
  agentRestartAttempts = 0;
  // Same structure as customerStopTranscription: a throw here must not leave
  // the agent channel half-torn-down and unusable on the next call.
  try {
    // ── REQ 1: Agent Stop also stops Customer transcription ────────────────────────
    // agentStopTranscription is the single control point for both sessions.
    // customerStopTranscription is idempotent, so calling it here is safe
    // even when onContactEnded has already called it explicitly.
    await customerStopTranscription().catch((e) =>
      console.error(
        `${LOGGER_PREFIX} - agentStopTranscription - customer teardown failed`, e,
      ),
    );
    // ───────────────────────────────────────────────────────────────────────────────
    if (AgentNovaSession) {
      await AgentNovaSession.stop().catch(() => {});
      AgentNovaSession = undefined;
    }
    // Stop AWS Transcribe before destroying the MicWorkletStream so the
    // adapter's AudioWorkletNode is torn down while the MediaStream is live.
    if (AgentTranscribeAdapter) {
      await AgentTranscribeAdapter.stop().catch(() => {});
      AgentTranscribeAdapter = null;
    }
    if (AmazonTranscribeToCustomerAudioStream) {
      // MicWorkletStream only needs destroy() — no setStream/stop.
      try {
        AmazonTranscribeToCustomerAudioStream.destroy();
      } catch (e) {
        console.error(
          `${LOGGER_PREFIX} - agentStopTranscription - stream destroy failed`,
          e,
        );
      }
      AmazonTranscribeToCustomerAudioStream = undefined;
    }
  } finally {
    // Dropdown was never disabled (kept always enabled for manual override),
    // so no re-enable needed here.
    CCP_V2V.UI.agentLoadingTranscriptionButton.style.display = "none";
    CCP_V2V.UI.agentStartTranscriptionButton.disabled = false;
    CCP_V2V.UI.agentStartTranscriptionButton.style.display = "";
    CCP_V2V.UI.agentStopTranscriptionButton.disabled = true;
    CCP_V2V.UI.agentStopTranscriptionButton.style.display = "none";

    enableMicrophoneAndSpeakerSelection();
  }
}

/**
 * CCP mute button handler. Connect broadcasts `muted: false` when a call's media
 * is torn down, so this state resets per call on its own.
 */
function onAgentMuteToggle({ muted }) {
  IsAgentMuted = muted === true;
  console.info(
    `${LOGGER_PREFIX} - onAgentMuteToggle - agent ${IsAgentMuted ? "muted" : "unmuted"}`,
  );
  applyAgentMuteState();
}

/** Raw-mic volume for the "Stream mic to customer" mix: 0 while muted. */
function getAgentRawMicVolume() {
  return IsAgentMuted ? 0 : parseFloat(CCP_V2V.UI.agentStreamMicVolume.value);
}

/**
 * Silence everything the agent's microphone feeds while the CCP is muted.
 *
 * CCP mute only disables the softphone's own mic track. This app captures the
 * mic separately (MicWorkletStream, which feeds both Nova Sonic and the
 * Transcribe adapter) and has replaced the outbound RTC track with the
 * translation track, so CCP mute alone reached none of it: muted speech was
 * still transcribed, translated and sent to the customer.
 *
 * The track is disabled, not stopped. A disabled track renders silence, so
 * Nova Sonic and Transcribe keep receiving the continuous stream they expect,
 * and the device stays open (no Bluetooth profile switch).
 *
 * Must be re-applied whenever the mic stream is re-created — a new track
 * starts enabled.
 */
function applyAgentMuteState() {
  const micStream = AmazonTranscribeToCustomerAudioStream?.getMediaStream?.();
  micStream?.getAudioTracks().forEach((track) => {
    track.enabled = !IsAgentMuted;
  });

  if (ToCustomerAudioStreamManager?.isMicrophoneEnabled()) {
    ToCustomerAudioStreamManager.setMicrophoneVolume(getAgentRawMicVolume());
  }
}

function loadInterpreterLanguages() {
  NOVA_INTERPRETER_LANGUAGES.forEach(({ code, name }) => {
    const option = document.createElement("option");
    option.value = code;
    option.textContent = name;

    CCP_V2V.UI.customerTranslateFromLanguageSelect.appendChild(option);
    // CCP_V2V.UI.customerTranslateToLanguageSelect.appendChild(option.cloneNode(true));

    CCP_V2V.UI.agentTranslateFromLanguageSelect.appendChild(
      option.cloneNode(true),
    );
    // CCP_V2V.UI.agentTranslateToLanguageSelect.appendChild(option.cloneNode(true));
  });

  CCP_V2V.UI.customerTranslateFromLanguageSelect.value = "en";
  // CCP_V2V.UI.customerTranslateToLanguageSelect.value = "es";
  CCP_V2V.UI.agentTranslateFromLanguageSelect.value = "en";
  // CCP_V2V.UI.agentTranslateToLanguageSelect.value = "es";

  // Customer language is always reset to English on login.
  // It will be overridden per-call by the "Customer_Preferred_Language" CCP
  // attribute once a call connects (populateCustomerInfo). We do NOT restore
  // the previously saved value here — a stale value from the last call must
  // never bleed into the next session.
  CCP_V2V.UI.customerTranslateFromLanguageSelect.value = "en";
  CCP_V2V.UI.customerTranslateFromLanguageSelect.disabled = false;
  addUpdateLocalStorageKey("customerTranslateFromLanguage", "en");

  // Always persist voiceId for the active customer language on every startup.
  // This ensures voiceId is never empty even before any call arrives or any
  // dropdown change event fires (fixes "voiceId cannot be empty" on first login).
  addUpdateLocalStorageKey(
    "customerNovaSonicVoiceId",
    getVoiceId(CCP_V2V.UI.customerTranslateFromLanguageSelect.value),
  );

  const savedAgentTranslateFromLanguage = getLocalStorageValueByKey(
    "agentTranslateFromLanguage",
  );
  if (savedAgentTranslateFromLanguage) {
    CCP_V2V.UI.agentTranslateFromLanguageSelect.value =
      savedAgentTranslateFromLanguage;
  } else {
    // First login — persist the default "en" so all downstream code always finds a language value.
    addUpdateLocalStorageKey(
      "agentTranslateFromLanguage",
      CCP_V2V.UI.agentTranslateFromLanguageSelect.value,
    );
  }
  // Always persist voiceId for the active agent language on every startup.
  addUpdateLocalStorageKey(
    "agentNovaSonicVoiceId",
    getVoiceId(CCP_V2V.UI.agentTranslateFromLanguageSelect.value),
  );
  const savedCustomerTranslateToLanguage = getLocalStorageValueByKey(
    "customerTranslateToLanguage",
  );
  /* if (savedCustomerTranslateToLanguage) {
    CCP_V2V.UI.customerTranslateToLanguageSelect.value = savedCustomerTranslateToLanguage;
  } */
  const savedAgentTranslateToLanguage = getLocalStorageValueByKey(
    "agentTranslateToLanguage",
  );
  if (savedAgentTranslateToLanguage) {
    // CCP_V2V.UI.agentTranslateToLanguageSelect.value = savedAgentTranslateToLanguage;
  }
}

/** fix 6: a typed message translated by Translate and spoken by Polly, as its own transcript turn. */
async function speakTypedTextViaBackup(text, fromLanguage, toLanguage) {
  AgentTurn.commit();
  AgentTurn.setOriginal(text, false);
  const result = await Promise.resolve()
    .then(() =>
      synthesizeFallbackTranslation({
        sourceText: text,
        sourceLangCode: fromLanguage,
        targetLangCode: toLanguage,
        translateRegion: TRANSLATE_CONFIG.region,
        pollyRegion: POLLY_CONFIG.region,
        quiet: true,
      }),
    )
    .catch(() => null);
  if (!result || !result.text) {
    console.error(`${LOGGER_PREFIX} - [BACKUP] typed message could not be translated`);
    raiseError("The typed message could not be translated (backup translation failed).");
    return;
  }
  BackupStats.incTyped();
  AgentTurn.pushTranslation(result.text);
  RecentSpokenToCustomer.add(result.text);
  if (result.audio && result.audio.length) {
    const playback = agentBackupPlay(new Uint8Array(result.audio));
    AgentFallbackPlayback = playback;
    await playback;
  }
  AgentTurn.commit();
  console.info(
    `${LOGGER_PREFIX} - [BACKUP] typed message -> customer${result.voiceLabel ? ` | ${result.voiceLabel}` : ""} | "${result.text.slice(0, 80)}"`,
  );
}

async function handleAgentTranslateText() {
  console.info("Inside handleAgentTranslateText().");
  if (!checkTranslationAllowed("handleAgentTranslateText")) return;
  const inputText = CCP_V2V.UI.agentTranslateTextInput.value.trim();
  if (isStringUndefinedNullEmpty(inputText)) return;
  // updateLiveSentiment(CCP_V2V.UI.agentSentimentValue, inputText);

  // Prefer the language pinned for this call so a typed message cannot be
  // spoken in a different language than the live speech session.
  const fromLanguage = AgentSessionConfig?.sourceLang
    ?? CCP_V2V.UI.agentTranslateFromLanguageSelect.value;
  const toLanguage = AgentSessionConfig?.targetLang
    ?? CCP_V2V.UI.customerTranslateFromLanguageSelect.value;
  // Voice must match the TARGET language. This path was still deriving it from
  // the SOURCE language — the bug "FIX 1" corrected on both speech paths but
  // never applied here.
  const voiceId = getVoiceId(toLanguage);

  // fix 6: while the agent side is not on Nova Sonic (or the switch is on), a typed message is translated
  // and spoken by the backup too.
  if ((TranslationActive && AgentFailover.state !== "nova") || ModePoller?.forceBackup) {
    await speakTypedTextViaBackup(inputText, fromLanguage, toLanguage);
    CCP_V2V.UI.agentTranslateTextInput.value = "";
    CCP_V2V.UI.agentTranslateTextInput.focus();
    return;
  }

  let assistantAccum = "";
  // fix 6: a Nova Sonic failure is handled once the attempt has ended (see below).
  let typedFailure = null;
  let typedAudioPlayed = false;
  // Close any speech turn still being assembled so the typed message cannot be
  // merged into it, then seed the typed text as this turn's original. Not
  // rendered into the "Agent said" box: the typed text is already on screen in
  // its own input field, and this path has never written that box.
  AgentTurn.commit();
  AgentTurn.setOriginal(inputText, false);
  try {
    await runNovaSonicTypedTextInterpretation({
      text: inputText,
      sourceLangCode: fromLanguage,
      targetLangCode: toLanguage,
      voiceId,
      handlers: {
        onAssistantText: (text) => {
          assistantAccum += text;
          AgentTurn.pushTranslation(text);
        },
        onAssistantAudioWav: async (wavBuf) => {
          typedAudioPlayed = true;
          // Both copies BEFORE the first playback: playAudioBuffer hands its
          // array's buffer to decodeAudioData, which detaches it, and
          // constructing a Uint8Array from a detached one throws outright.
          // This mirrors playTranslationAudio() on the speech path — the helper
          // lives in the session closure and is not reachable from here.
          const wantsMonitor =
            CCP_V2V.UI.agentStreamTranslationCheckbox.checked === true &&
            ToAgentAudioStreamManager != null;
          const forCustomer = new Uint8Array(wavBuf);
          const forAgent = wantsMonitor ? new Uint8Array(wavBuf) : null;

          if (ToCustomerAudioStreamManager != null) {
            await ToCustomerAudioStreamManager.playAudioBuffer(forCustomer);
          }
          if (forAgent) {
            await ToAgentAudioStreamManager.playAudioBuffer(
              forAgent,
              AGENT_TRANSLATION_TO_AGENT_VOLUME,
            );
          }
        },
        onError: (err) => {
          console.error(`${LOGGER_PREFIX} - agent typed Nova Sonic`, err);
          typedFailure = typedFailure || err;
        },
      },
    });
    AgentTurn.commit();
  } catch (error) {
    console.error(`${LOGGER_PREFIX} - handleAgentTranslateText`, error);
    typedFailure = typedFailure || error;
  }
  if (typedFailure) {
    // fix 6: Nova Sonic failed before saying anything, so the backup translates and speaks the message.
    // Once Nova Sonic had started speaking it, the agent is told, as before.
    if (!typedAudioPlayed && isBackupWorthy(typedFailure)) {
      await speakTypedTextViaBackup(inputText, fromLanguage, toLanguage);
    } else {
      raiseError(`Nova Sonic (typed): ${typedFailure?.message || typedFailure}`);
    }
  }

  CCP_V2V.UI.agentTranslateTextInput.value = "";
  CCP_V2V.UI.agentTranslateTextInput.focus();
}

function populateCustomerInfo(contact) {
  console.info("Contact Details: ", contact);
  const attrs = contact.getAttributes();
  
  const initiationMethod = contact.getInitiationMethod?.() ?? "UNKNOWN";
  const isOutbound = initiationMethod?.toLowerCase() !== "inbound";

  // Helper: safely read attribute value or fallback to '-'
  const getAttr = (key) => attrs[key]?.value?.trim() || "-";
  console.info("Contact attributes populated: ", attrs);
  console.info("InitiationMethod: ", initiationMethod);
  // Fields available for ALL call types
  document.getElementById("ciUserId").textContent = getAttr("UserId (511)");
  document.getElementById("ciCallerName").textContent = getAttr("CallerName");
  document.getElementById("ciUPI").textContent = getAttr("UPI");
  document.getElementById("ciHiredStatus").textContent = getAttr("HiredStatus");
  document.getElementById("ciIntent").textContent = getAttr("Intent");
  document.getElementById("ciQueue").textContent = getAttr("Queue");
  document.getElementById("ciDialedNumber").textContent =
    getAttr("Dialed-Number");

  // VerificationStatus & VerifiedVia — only applicable for INBOUND calls
  // (no IVR verification happens on outbound calls)
  if (isOutbound) {
    document.getElementById("ciVerificationStatus").textContent = "-";
    document.getElementById("ciVerifiedVia").textContent = "-";
  } else {
    document.getElementById("ciVerificationStatus").textContent =
      getAttr("VerificationStatus");
    document.getElementById("ciVerifiedVia").textContent =
      getAttr("VerifiedVia");
  }

  // ── Customer language auto-set (INBOUND only) ────────────────────────────
  // For INBOUND calls: read the "Customer_Preferred_Language" CCP attribute,
  // apply it to the customer language dropdown (fallback to "en" if missing or
  // unsupported), then DISABLE the dropdown so it cannot be changed mid-call.
  // For OUTBOUND calls: leave the dropdown at its current value and keep it
  // enabled so the agent can adjust freely.
  if (!isOutbound) {
    const preferredLang = attrs["Customer_Preferred_Language"]?.value?.trim() || "";
    console.info(
      `${LOGGER_PREFIX} - populateCustomerInfo - Customer_Preferred_Language attribute: "${preferredLang}"`,
    );

    const resolvedLang = autoSetCustomerLanguageFromAttribute(
      preferredLang,
      CCP_V2V.UI.customerTranslateFromLanguageSelect,
      addUpdateLocalStorageKey,
    );

    // Programmatic selectEl.value changes do NOT fire the DOM 'change' event,
    // so explicitly persist the matching voiceId here.
    addUpdateLocalStorageKey("customerNovaSonicVoiceId", getVoiceId(resolvedLang));

    // Lock the dropdown for the duration of this INBOUND call.
    // CCP_V2V.UI.customerTranslateFromLanguageSelect.disabled = true;

    console.info(
      `${LOGGER_PREFIX} - populateCustomerInfo - customer language set to "${resolvedLang}" and dropdown disabled (INBOUND)`,
    );
  } else {
    console.info(
      `${LOGGER_PREFIX} - populateCustomerInfo - OUTBOUND call, skipping customer language auto-set and leaving dropdown enabled`,
    );
  }

  console.info(
    `${LOGGER_PREFIX} - populateCustomerInfo - populated for ${initiationMethod} call`,
  );
}

function clearCustomerInfo() {
  const fieldIds = [
    "ciUserId",
    "ciCallerName",
    "ciVerificationStatus",
    "ciVerifiedVia",
    "ciUPI",
    "ciHiredStatus",
    "ciIntent",
    "ciQueue",
    "ciDialedNumber",
  ];
  fieldIds.forEach((id) => {
    document.getElementById(id).textContent = "-";
  });
  console.info(`${LOGGER_PREFIX} - clearCustomerInfo - all fields reset`);
}

function cleanUpUI() {
  // reset() blanks both boxes and drops the in-flight turn, so a pending
  // settle timer cannot fire after teardown and append a bubble from the call
  // that just ended onto the next one.
  CustomerTurn.reset();
  clearCustomerInfo();

  CCP_V2V.UI.customerTranscriptionTextOutputDiv.textContent = "";
  setBackgroundColour(CCP_V2V.UI.customerTranscriptionTextOutputDiv);

  AgentTurn.reset();
  setBackgroundColour(CCP_V2V.UI.agentTranscriptionTextOutputDiv);

  CCP_V2V.UI.agentTranslateTextInput.value = "";
  // updateLiveSentiment(CCP_V2V.UI.customerSentimentValue, "");
  // updateLiveSentiment(CCP_V2V.UI.agentSentimentValue, "");

  CCP_V2V.UI.customerLoadingTranscriptionButton.style.display = "none";
  CCP_V2V.UI.customerStartTranscriptionButton.disabled = true;
  CCP_V2V.UI.customerStartTranscriptionButton.style.display = "";
  CCP_V2V.UI.customerStopTranscriptionButton.style.display = "none";
  CCP_V2V.UI.agentLoadingTranscriptionButton.style.display = "none";
  CCP_V2V.UI.agentStartTranscriptionButton.disabled = true;
  CCP_V2V.UI.agentStartTranscriptionButton.style.display = "";
  CCP_V2V.UI.agentStopTranscriptionButton.style.display = "none";

  // Reset customer language to English and re-enable the dropdown.
  // The language was locked (disabled) for the duration of the INBOUND call;
  // restoring it here ensures the agent starts the next call in a clean state.
  CCP_V2V.UI.customerTranslateFromLanguageSelect.value = "en";
  CCP_V2V.UI.customerTranslateFromLanguageSelect.disabled = false;
  addUpdateLocalStorageKey("customerTranslateFromLanguage", "en");
  addUpdateLocalStorageKey("customerNovaSonicVoiceId", getVoiceId("en"));
  console.info(
    `${LOGGER_PREFIX} - cleanUpUI - customer language reset to "en" and dropdown re-enabled`,
  );

  enableMicrophoneAndSpeakerSelection();
}

function raiseError(errorMessage) {
  alert(`${errorMessage}`);
}

function setBackgroundColour(element, cssClass) {
  // Remove all background classes first
  element.classList.remove("bg-pale-green", "bg-pale-yellow", "bg-none");

  // Add the requested background if specified
  if (cssClass) {
    element.classList.add(cssClass);
  }
}

function calculateSentimentLabel(text) {
  const normalized = (text || "").toLowerCase();
  if (!normalized.trim()) return "Neutral";

  const positiveWords = [
    "good",
    "great",
    "happy",
    "satisfied",
    "thank",
    "thanks",
    "awesome",
    "perfect",
    "excellent",
    "helpful",
    "love",
  ];
  const negativeWords = [
    "angry",
    "upset",
    "bad",
    "terrible",
    "frustrated",
    "issue",
    "problem",
    "not working",
    "hate",
    "awful",
    "disappointed",
  ];

  let score = 0;
  positiveWords.forEach((w) => {
    if (normalized.includes(w)) score += 1;
  });
  negativeWords.forEach((w) => {
    if (normalized.includes(w)) score -= 1;
  });

  if (score <= -2) return "Angry";
  if (score < 0) return "Frustrated";
  if (score >= 2) return "Satisfied";
  if (score > 0) return "Positive";
  return "Neutral";
}

function sentimentClassFor(label) {
  if (label === "Angry" || label === "Frustrated") return "sentiment-negative";
  if (label === "Satisfied" || label === "Positive")
    return "sentiment-positive";
  return "sentiment-neutral";
}

function updateLiveSentiment(element, text) {
  if (!element) return;
  const label = calculateSentimentLabel(text);
  element.textContent = label;
  element.classList.remove(
    "sentiment-neutral",
    "sentiment-positive",
    "sentiment-negative",
  );
  element.classList.add(sentimentClassFor(label));
}

function addTranscriptCard(originalTranscript, translatedTranscript, type) {
  // Delegates entirely to the standalone conversationTranscript.js module.
  // Signature unchanged — all existing call-sites are untouched.
  addConversationMessage(
    originalTranscript,
    translatedTranscript,
    type,
    CCP_V2V.UI.agentTranslateFromLanguageSelect,
    CCP_V2V.UI.customerTranslateFromLanguageSelect,
  );
}

function clearTranscriptCards() {
  // Delegates to the standalone conversationTranscript.js module.
  clearConversationTranscript();
}

function getMicrophoneConstraints(deviceId) {
  let microphoneConstraints = {
    audio: {
      deviceId: deviceId,
      echoCancellation: CCP_V2V.UI.echoCancellationCheckbox.checked === true,
      noiseSuppression: CCP_V2V.UI.noiseSuppressionCheckbox.checked === true,
      autoGainControl: CCP_V2V.UI.autoGainControlCheckbox.checked === true,
    },
  };

  console.info(
    `${LOGGER_PREFIX} - getMicrophoneConstraints: ${JSON.stringify(microphoneConstraints)}`,
  );
  return microphoneConstraints;
}

function enableMicrophoneAndSpeakerSelection() {
  CCP_V2V.UI.micSelect.disabled = false;
  CCP_V2V.UI.speakerSelect.disabled = false;

  CCP_V2V.UI.testAudioButton.disabled = false;
  CCP_V2V.UI.speakerSaveButton.disabled = false;

  CCP_V2V.UI.testMicButton.disabled = false;
  CCP_V2V.UI.micSaveButton.disabled = false;

  CCP_V2V.UI.echoCancellationCheckbox.disabled = false;
  CCP_V2V.UI.noiseSuppressionCheckbox.disabled = false;
  CCP_V2V.UI.autoGainControlCheckbox.disabled = false;
}

function disableMicrophoneAndSpeakerSelection() {
  CCP_V2V.UI.micSelect.disabled = true;
  CCP_V2V.UI.speakerSelect.disabled = true;

  CCP_V2V.UI.testAudioButton.disabled = true;
  CCP_V2V.UI.speakerSaveButton.disabled = true;

  CCP_V2V.UI.testMicButton.disabled = true;
  CCP_V2V.UI.micSaveButton.disabled = true;

  CCP_V2V.UI.echoCancellationCheckbox.disabled = true;
  CCP_V2V.UI.noiseSuppressionCheckbox.disabled = true;
  CCP_V2V.UI.autoGainControlCheckbox.disabled = true;
}

/**
 * Shows a green toast notification in the top-right corner.
 */
function showToast(message, duration = 3000) {
  const container = document.getElementById("toastContainer");
  if (!container) return;

  const toast = document.createElement("div");
  toast.className = "toast toast-success";
  toast.innerHTML = `
    <span class="toast-icon">&#10003;</span>
    <span class="toast-msg">${message}</span>
    <button class="toast-close" title="Dismiss">&#10005;</button>
  `;

  toast
    .querySelector(".toast-close")
    .addEventListener("click", () => removeToast(toast));

  container.appendChild(toast);

  requestAnimationFrame(() => toast.classList.add("toast-show"));

  // Auto-dismiss after duration
  setTimeout(() => removeToast(toast), duration);
}

function removeToast(toast) {
  toast.classList.remove("toast-show");
  toast.classList.add("toast-hide");
  toast.addEventListener("transitionend", () => toast.remove(), { once: true });
}

/**
 * Returns the Nova Sonic voice ID for the given BCP-47 language code.
 */
function getVoiceId(languageCode) {
  if (!languageCode) return DEFAULT_VOICE_ID;

  const mapped = LANGUAGE_VOICE_ID_MAP[languageCode];
  if (!mapped) {
    // DEFAULT_VOICE_ID is "matthew", an English-US voice. Handing it to a
    // session whose target is (say) Japanese asks Nova Sonic to speak Japanese
    // in an English voice, which pushes it back toward English output — the
    // very drift "FIX 1" identified. We still fall back so the call proceeds,
    // but it must not be silent: only 5 of the 22 offered languages have a
    // genuine Nova Sonic voice.
    console.error(
      `${LOGGER_PREFIX} - getVoiceId: no Nova Sonic voice mapped for "${languageCode}" —` +
      ` falling back to "${DEFAULT_VOICE_ID}" (English). Output quality will be degraded` +
      ` and the Translate+Polly fallback may be used frequently.`
    );
    return DEFAULT_VOICE_ID;
  }

  // Guard against a mapping that names a voice Nova Sonic does not know
  // (the model ignores it and speaks English, which reads as an untranslated
  // passthrough to the customer). fix 7: NOVA_SONIC_VOICE_IDS is now Nova 2
  // Sonic's list, in which "kiara" (Hindi) and "carolina" (Portuguese) are valid.
  if (!NOVA_SONIC_VOICE_IDS.some((v) => v.id === mapped)) {
    console.error(
      `${LOGGER_PREFIX} - getVoiceId: "${mapped}" (mapped for "${languageCode}") is not a` +
      ` known Nova Sonic voice — falling back to "${DEFAULT_VOICE_ID}"`
    );
    return DEFAULT_VOICE_ID;
  }

  return mapped;
}
