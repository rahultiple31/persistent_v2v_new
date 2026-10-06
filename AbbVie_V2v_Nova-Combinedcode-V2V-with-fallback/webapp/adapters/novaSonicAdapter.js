// Copyright 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import { LOGGER_PREFIX } from "../constants";
import { NOVA_SONIC_CONFIG, PROXY_CONFIG } from "../config";
import { getValidAwsCredentials, hasValidAwsCredentials } from "../utils/authUtility";
import { openNovaProxyStream } from "../utils/proxyTransport";
import { createPcm16Downsampler, pcm16MonoToWavArrayBuffer } from "../utils/novaSonicAudioUtils";
import { buildInterpreterPrompt } from "./interpreterPrompts";

const NOVA_INPUT_SAMPLE_RATE = 16000;
const NOVA_OUTPUT_SAMPLE_RATE = 24000;
const TEXT_ENCODER = new TextEncoder();

let _bedrockClient;

// fix 7: the Nova 2 Sonic voices, from AWS's "Language support and multilingual capabilities" page
// (Amazon Nova 2 user guide), checked 2026-09-30. The list before was Nova Sonic v1's: German was "greta"
// (Nova 2: tina) and Portuguese, Hindi and English (Australia, India) had no voice. tiffany and matthew
// are polyglot: they speak every Nova 2 Sonic language. Dutch, Japanese and Mandarin are not Nova 2 Sonic
// languages, so no voice exists for them.
export const NOVA_SONIC_VOICE_IDS = [
  { id: "tiffany", label: "Tiffany (English US, feminine, polyglot)" },
  { id: "matthew", label: "Matthew (English US, masculine, polyglot)" },
  { id: "amy", label: "Amy (English GB, feminine)" },
  { id: "olivia", label: "Olivia (English Australia, feminine)" },
  { id: "kiara", label: "Kiara (English India and Hindi, feminine)" },
  { id: "arjun", label: "Arjun (English India and Hindi, masculine)" },
  { id: "ambre", label: "Ambre (French, feminine)" },
  { id: "florian", label: "Florian (French, masculine)" },
  { id: "beatrice", label: "Beatrice (Italian, feminine)" },
  { id: "lorenzo", label: "Lorenzo (Italian, masculine)" },
  { id: "tina", label: "Tina (German, feminine)" },
  { id: "lennart", label: "Lennart (German, masculine)" },
  { id: "lupe", label: "Lupe (Spanish US, feminine)" },
  { id: "carlos", label: "Carlos (Spanish US, masculine)" },
  { id: "carolina", label: "Carolina (Portuguese Brazil, feminine)" },
  { id: "leo", label: "Leo (Portuguese Brazil, masculine)" },
];

async function getBedrockRuntimeClient() {
  if (_bedrockClient != null && hasValidAwsCredentials()) {
    return _bedrockClient;
  }
  const [credentials, { BedrockRuntimeClient }] = await Promise.all([
    getValidAwsCredentials(),
    import("@aws-sdk/client-bedrock-runtime"),
  ]);
  _bedrockClient = new BedrockRuntimeClient({
    region: NOVA_SONIC_CONFIG.bedrockRegion,
    credentials: {
      accessKeyId: credentials.accessKeyId,
      secretAccessKey: credentials.secretAccessKey,
      sessionToken: credentials.sessionToken,
    },
  });
  return _bedrockClient;
}

export function invalidateBedrockClient() {
  _bedrockClient = null;
}

/**
 * Returns a function that opens one Nova Sonic bidirectional stream over `queue` and resolves to a
 * response whose `body` yields Bedrock output events.
 *
 * With the proxy enabled the stream runs through the server-side proxy and no AWS credentials exist in
 * the browser; the model ID is then set on the proxy. Otherwise the browser calls Bedrock directly.
 * The AWS SDK is imported only in direct mode, so the proxy build never loads it.
 */
async function prepareNovaStream() {
  if (PROXY_CONFIG.enabled) return openNovaProxyStream;
  const [client, { InvokeModelWithBidirectionalStreamCommand }] = await Promise.all([
    getBedrockRuntimeClient(),
    import("@aws-sdk/client-bedrock-runtime"),
  ]);
  const modelId = NOVA_SONIC_CONFIG.modelId || "amazon.nova-2-sonic-v1:0";
  return (queue) => client.send(new InvokeModelWithBidirectionalStreamCommand({ modelId, body: queue }));
}

function delay(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function toBase64(bytes) {
  let binary = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}

/**
 * AsyncIterable body for InvokeModelWithBidirectionalStream (matches AWS Nova samples pattern).
 */
class NovaOutboundQueue {
  constructor() {
    this._events = [];
    this._waiter = null;
    this._closed = false;
  }

  enqueueEvent(eventObject) {
    if (this._closed) return;
    const payload = TEXT_ENCODER.encode(JSON.stringify(eventObject));
    const sdkChunk = { chunk: { bytes: payload } };
    if (this._waiter) {
      const resolve = this._waiter;
      this._waiter = null;
      resolve({ value: sdkChunk, done: false });
    } else {
      this._events.push(sdkChunk);
    }
  }

  close() {
    this._closed = true;
    if (this._waiter) {
      this._waiter({ value: undefined, done: true });
      this._waiter = null;
    }
  }

  [Symbol.asyncIterator]() {
    return {
      next: async () => {
        if (this._events.length > 0) {
          return { value: this._events.shift(), done: false };
        }
        if (this._closed) {
          return { value: undefined, done: true };
        }
        return await new Promise((resolve) => {
          this._waiter = resolve;
        });
      },
      return: async () => {
        this._closed = true;
        return { value: undefined, done: true };
      },
    };
  }
}


async function enqueueInterpreterSessionStartAndSystem(queue, { voiceId, systemPrompt, promptName, textContentName }) {
  queue.enqueueEvent({
    event: {
      sessionStart: {
        inferenceConfiguration: {
          // Lower temperature (0.1) and topP (0.7) to reduce Nova Sonic's
          // tendency to add creative parenthetical meta-commentary that was
          // not part of the original spoken text (Issue 2 fix).
          maxTokens: 1024,
          topP: 0.7,
          temperature: 0.1,
        },
      },
    },
  });
  queue.enqueueEvent({
    event: {
      promptStart: {
        promptName,
        textOutputConfiguration: { mediaType: "text/plain" },
        audioOutputConfiguration: {
          mediaType: "audio/lpcm",
          sampleRateHertz: NOVA_OUTPUT_SAMPLE_RATE,
          sampleSizeBits: 16,
          channelCount: 1,
          voiceId,
          encoding: "base64",
          audioType: "SPEECH",
        },
      },
    },
  });
  queue.enqueueEvent({
    event: {
      contentStart: {
        promptName,
        contentName: textContentName,
        type: "TEXT",
        interactive: true,
        role: "SYSTEM",
        textInputConfiguration: { mediaType: "text/plain" },
      },
    },
  });
  queue.enqueueEvent({
    event: {
      textInput: {
        promptName,
        contentName: textContentName,
        content: systemPrompt,
      },
    },
  });
  queue.enqueueEvent({
    event: {
      contentEnd: {
        promptName,
        contentName: textContentName,
      },
    },
  });
}

async function enqueueUserAudioContentStart(queue, { promptName, audioContentName }) {
  queue.enqueueEvent({
    event: {
      contentStart: {
        promptName,
        contentName: audioContentName,
        type: "AUDIO",
        interactive: true,
        role: "USER",
        audioInputConfiguration: {
          mediaType: "audio/lpcm",
          sampleRateHertz: NOVA_INPUT_SAMPLE_RATE,
          sampleSizeBits: 16,
          channelCount: 1,
          audioType: "SPEECH",
          encoding: "base64",
        },
      },
    },
  });
}

/**
 * Fill the outbound queue with the events that open a Nova Sonic session.
 *
 * Every enqueue here happens BEFORE client.send() — the queue is a plain FIFO
 * array that the SDK only begins draining once the request is in flight, and
 * it preserves order by construction. The six `await delay(30)` calls that
 * used to separate these enqueues therefore paced nothing: they added a flat
 * 180ms to every session start, on both the agent and the customer channel,
 * and again on every reconnect. Removed.
 *
 * The delays elsewhere in this file are NOT equivalent — those run while the
 * stream is live and do pace the wire.
 */
async function enqueueSessionPreamble(queue, opts) {
  await enqueueInterpreterSessionStartAndSystem(queue, {
    voiceId: opts.voiceId,
    systemPrompt: opts.systemPrompt,
    promptName: opts.promptName,
    textContentName: opts.textContentName,
  });
  await enqueueUserAudioContentStart(queue, { promptName: opts.promptName, audioContentName: opts.audioContentName });
}

async function enqueueUserTextContentTurn(queue, { promptName, userTextContentName, text }) {
  queue.enqueueEvent({
    event: {
      contentStart: {
        promptName,
        contentName: userTextContentName,
        type: "TEXT",
        interactive: true,
        role: "USER",
        textInputConfiguration: { mediaType: "text/plain" },
      },
    },
  });
  await delay(20);
  queue.enqueueEvent({
    event: {
      textInput: {
        promptName,
        contentName: userTextContentName,
        content: text,
      },
    },
  });
  await delay(20);
  queue.enqueueEvent({
    event: {
      contentEnd: {
        promptName,
        contentName: userTextContentName,
      },
    },
  });
  await delay(20);
}

// Nova Sonic status strings that occasionally leak into textOutput.content
// on interrupted or error turns. These are model-internal metadata strings
// and must never be shown in the UI or passed to onUserText.
const NOVA_STATUS_STRINGS = [
  /^interrupted\s*[=:]\s*true$/i,
  /^\[interrupted\]$/i,
  /^interrupted$/i,
  /^\[barge.?in\]$/i,
  /^stop.?reason\s*[=:]\s*interrupted$/i,
  // JSON object format: { "interrupted" : true } — Nova Sonic leaks this in
  // agent sessions after a barge-in. Must be caught BEFORE it pollutes
  // lastAssistantTextAcrossTurns and breaks Layer 4 cross-turn matching.
  /^\{\s*["']interrupted["']\s*:\s*true\s*\}$/i,
];

function isNovaStatusString(text) {
  const t = (text || "").trim();
  return NOVA_STATUS_STRINGS.some((re) => re.test(t));
}

/**
 * Sanitize ASSISTANT text content to strip embedded role labels.
 *
 * ROOT CAUSE (Rule 18 backfire):
 *   When a system prompt mentions "USER role" and "ASSISTANT role" as
 *   instructions, Nova Sonic misinterprets them as TEXT FORMAT directives
 *   and starts prefixing its output with literal labels like:
 *     "USER: necesito tu número..."
 *     "ASSISTANT: I need your social security..."
 *   …all inside a single ASSISTANT text block. This causes:
 *     1. The translation box shows both "USER:" and "ASSISTANT:" labels.
 *     2. Layer 5 fuzzy-matches the legitimate English USER text against the
 *        "ASSISTANT: I need your..." portion → incorrectly retracts it.
 *     3. lastAssistantTextAcrossTurns gets corrupted with role-label prefixes.
 *
 * This sanitizer strips these leaked role-label prefixes from ASSISTANT
 * content before it reaches any tracking variable or UI callback.
 *
 * Handles patterns:
 *   "USER: <text>\nASSISTANT: <translation>"
 *   "USER:<text>\nASSISTANT:<translation>"
 *   Bare "ASSISTANT: <text>" or "USER: <text>" prefixes
 *   Mixed-case variants (User:, user:, etc.)
 */
function sanitizeAssistantContent(text) {
  if (!text) return text;

  // Pattern 1: "USER: <src>\nASSISTANT: <tgt>" — extract only the ASSISTANT part
  const splitPattern = /^\s*USER\s*:\s*.+?\n+\s*ASSISTANT\s*:\s*/is;
  if (splitPattern.test(text)) {
    const cleaned = text.replace(/^\s*USER\s*:\s*.+?\n+\s*ASSISTANT\s*:\s*/is, "").trim();
    console.warn(
      `${LOGGER_PREFIX} - [SANITIZE] Stripped USER+ASSISTANT role labels from ASSISTANT content` +
      ` | original: "${text.slice(0, 80)}" | cleaned: "${cleaned.slice(0, 80)}"`
    );
    return cleaned;
  }

  // Pattern 2: bare "ASSISTANT: <text>" prefix at start
  const assistantPrefix = /^\s*ASSISTANT\s*:\s*/i;
  if (assistantPrefix.test(text)) {
    const cleaned = text.replace(assistantPrefix, "").trim();
    console.warn(
      `${LOGGER_PREFIX} - [SANITIZE] Stripped bare ASSISTANT: prefix from content` +
      ` | cleaned: "${cleaned.slice(0, 80)}"`
    );
    return cleaned;
  }

  // Pattern 3: bare "USER: <text>" prefix at start of ASSISTANT block
  // (model output entire source text under wrong label inside ASSISTANT block)
  const userPrefix = /^\s*USER\s*:\s*/i;
  if (userPrefix.test(text)) {
    const cleaned = text.replace(userPrefix, "").trim();
    console.warn(
      `${LOGGER_PREFIX} - [SANITIZE] Stripped bare USER: prefix from ASSISTANT content` +
      ` | cleaned: "${cleaned.slice(0, 80)}"`
    );
    return cleaned;
  }

  return text;
}

/**
 * Cross-turn fuzzy match — Layer 4 misfire detection.
 *
 * Nova Sonic splits what should be one turn into TWO completionEnd-terminated
 * turns. The misfire (translated text under USER role) arrives in the SECOND
 * turn — AFTER completionEnd has already reset all per-turn flags. This means
 * Layers 1-3 all see a clean, structurally-legitimate USER block and pass it
 * through.
 *
 * The only reliable discriminator is content: the misfire USER text is always
 * the same text (or highly similar) to the ASSISTANT text from the PREVIOUS
 * turn. We track lastAssistantTextAcrossTurns across completionEnd boundaries
 * and fuzzy-match every incoming USER text against it.
 *
 * Match criteria (any one is sufficient to flag as misfire):
 *  1. Exact string match (normalised, trimmed)
 *  2. One string fully contains the other (≥ 70% of the shorter one's length)
 *  3. Word-level Jaccard similarity ≥ 0.55
 */
function crossTurnFuzzyMatch(userText, lastAssistantText) {
  // Intentionally strict (0.70 containment ratio, 0.55 Jaccard) because
  // cross-turn comparisons span unrelated turns and must avoid false positives.
  // For same-turn Layer 5 matching use sameTurnMisfireMatch() instead.
  if (!userText || !lastAssistantText) return false;
  const u = userText.trim().toLowerCase();
  const a = lastAssistantText.trim().toLowerCase();
  if (!u || !a) return false;

  // 1. Exact match
  if (u === a) return true;

  // 2. Containment — one string is a substring of the other
  //    (misfire sometimes truncates or extends the translation slightly)
  const shorter = u.length <= a.length ? u : a;
  const longer  = u.length <= a.length ? a : u;
  if (shorter.length > 0 && longer.includes(shorter) &&
      shorter.length / longer.length >= 0.70) return true;

  // 3. Word-level Jaccard similarity
  const uWords = new Set(u.split(/\s+/).filter(Boolean));
  const aWords = new Set(a.split(/\s+/).filter(Boolean));
  if (uWords.size === 0 || aWords.size === 0) return false;
  const intersection = [...uWords].filter(w => aWords.has(w)).length;
  const union = new Set([...uWords, ...aWords]).size;
  return union > 0 && (intersection / union) >= 0.55;
}

/**
 * Same-turn misfire match — Layer 5 misfire detection.
 *
 * WHY THIS IS NEEDED (separate from crossTurnFuzzyMatch):
 *   crossTurnFuzzyMatch uses strict thresholds (0.70 containment ratio,
 *   0.55 Jaccard) designed for cross-turn comparisons where false positives
 *   would suppress legitimate speech across unrelated turns.
 *
 *   For Layer 5 (same-turn), the misfire USER text is always a FRAGMENT or
 *   CHUNK of the ASSISTANT translation emitted in the SAME turn. The pattern
 *   in logs is:
 *     USER: "para autenticarte primero y luego podemos proceder con el"  ← chunk
 *     USER: "problema"                                                    ← chunk
 *     ASSISTANT: "entendido, así que voy a requerir algunos de tus       ← full
 *                  detalles para autenticarte primero y luego podemos
 *                  proceder con el problema"
 *
 *   The crossTurnFuzzyMatch FAILS here because:
 *     - Containment ratio: 55/120 = 0.45  → below 0.70 threshold
 *     - Jaccard:           9/20  = 0.45  → below 0.55 threshold
 *
 *   This function uses DIRECTIONAL containment (no ratio limit) and a lower
 *   Jaccard threshold (0.40), safe because within the same turn we know the
 *   ASSISTANT text is the translation and the USER text should be the agent's
 *   original language — any same-language overlap is highly suspicious.
 *
 * Match criteria (any one sufficient):
 *  1. Exact match
 *  2. ASSISTANT text contains USER text (directional, no ratio — catches fragments)
 *  3. USER text contains ASSISTANT text (reverse containment)
 *  4. Word-level Jaccard ≥ 0.40 (lower threshold safe for same-turn)
 *
 * Minimum length guard: userText must be ≥ 15 chars to avoid false positives
 * on short common words that appear in both languages (e.g. "no", "si").
 */
function sameTurnMisfireMatch(userText, assistantText) {
  if (!userText || !assistantText) return false;
  const u = userText.trim().toLowerCase();
  const a = assistantText.trim().toLowerCase();
  // Short strings are unreliable — common words appear in both languages.
  if (!u || !a || u.length < 15) return false;

  // 1. Exact match
  if (u === a) return true;

  // 2. Directional containment: ASSISTANT contains USER fragment (no ratio limit).
  //    Most common pattern: misfire chunk is a substring of full translation.
  if (a.includes(u)) return true;

  // 3. Reverse containment: USER contains ASSISTANT.
  if (u.includes(a) && a.length >= 15) return true;

  // 4. Word-level Jaccard with lower threshold (0.40) safe for same-turn.
  const uWords = new Set(u.split(/\s+/).filter(Boolean));
  const aWords = new Set(a.split(/\s+/).filter(Boolean));
  if (uWords.size === 0 || aWords.size === 0) return false;
  const intersection = [...uWords].filter(w => aWords.has(w)).length;
  const union = new Set([...uWords, ...aWords]).size;
  return union > 0 && (intersection / union) >= 0.40;
}

async function processResponseStream(responseBody, handlers, sessionState, sessionLabel = "UNKNOWN") {
  if (!responseBody) return;

  // ─── Role-misfire suppression (two-layer) ────────────────────────────────
  //
  // LAYER 1 — closed-block check:
  //   contentBlockRoles  : maps contentName → declared role from contentStart
  //   closedContentBlocks: contentNames that have received contentEnd
  //   If a textOutput arrives for a closed block → misfire → suppress.
  //
  // LAYER 2 — post-assistant USER-block check:
  //   The dominant misfire pattern is Nova Sonic opening a BRAND NEW content
  //   block with role="USER" and emitting the translated text through it,
  //   AFTER the ASSISTANT block for that turn has already closed. This block
  //   is fresh (never been closed) so Layer 1 cannot catch it.
  //   Fix: track whether an ASSISTANT block has opened AND closed in this
  //   turn (assistantBlockClosedThisTurn). If true, any subsequent
  //   contentStart with role="USER" is a misfire — suppress its textOutput.
  //
  // ─── Interrupted-turn suppression ────────────────────────────────────────
  //   completionEnd carries interrupted:true when Nova Sonic cuts off its
  //   own output (barge-in / VAD). Pass the flag to onTurnComplete so
  //   handlers can skip writing incomplete transcript cards.
  // ──────────────────────────────────────────────────────────────────────────
  const contentBlockRoles = {};          // contentName → role string
  const closedContentBlocks = new Set(); // contentNames whose contentEnd arrived
  let assistantBlockClosedThisTurn = false; // true once ASSISTANT block has closed
  let currentBlockIsMisfire = false;     // true for blocks identified as misfires
  // Layer 3: track whether we are currently INSIDE an ASSISTANT content block
  // (between its contentStart and contentEnd). A textOutput with role="USER"
  // and no contentName arriving while inside an ASSISTANT block is a misfire.
  let currentlyInsideAssistantBlock = false;

  // Layer 5 — same-turn pre-ASSISTANT USER misfire detection.
  //
  // ROOT CAUSE (agent-side only, invisible on customer side):
  //   Nova Sonic emits the TRANSLATED text as rawRole="USER" BEFORE it opens
  //   the ASSISTANT content block — within the same completionEnd turn.
  //   At the moment of misfire all structural flags are clean/reset:
  //     insideAssistantBlock=false, assistantClosedThisTurn=false, contentName=null
  //   so Layers 1-3 see nothing wrong. Layer 4 compares against the PREVIOUS
  //   turn's assistant text (different content) so it also misses.
  //
  //   On the customer side the same misfire pattern produces target-language
  //   (English) text as USER — but the customer's genuine speech is Spanish,
  //   so any English USER misfire looks obviously wrong... except the logs show
  //   no customer-side misfires, meaning the model only does this on the agent
  //   session (English→Spanish direction).
  //
  // FIX:
  //   Collect all USER and ASSISTANT texts emitted within the current turn.
  //   At completionEnd, fuzzy-compare every USER text against every ASSISTANT
  //   text from that same turn. Any USER text that matches an ASSISTANT text is
  //   a pre-ASSISTANT misfire. Fire onUserTextRetraction() so the UI can clear
  //   the incorrectly displayed translation from the source-speech box.
  let turnUserTexts   = []; // { content } — USER texts emitted this turn
  let turnAssistantTexts = []; // string[]    — ASSISTANT texts seen this turn

  // Layer 4 — cross-turn last-assistant tracking.
  // Nova Sonic splits one logical turn into TWO completionEnd-terminated turns.
  // The misfire USER text arrives in the SECOND turn, AFTER completionEnd has
  // reset all per-turn flags (Layers 1-3 all see a clean USER block and pass
  // it). The only discriminator is content: the misfire text is always the
  // same (or very similar) to the ASSISTANT text from the immediately
  // preceding turn. We persist this value ACROSS completionEnd boundaries so
  // the cross-turn fuzzy check can catch it.
  let lastAssistantTextAcrossTurns = "";

  let displayAssistantText = false;

  // ─── Audio vetting ────────────────────────────────────────────────────────
  // audioOutput used to be forwarded unconditionally, which made the whole
  // drift/refusal guard bypassable: Layers 1-5 and displayAssistantText filter
  // TEXT only. When an ASSISTANT contentStart carries no additionalModelFields,
  // displayAssistantText stays false ("FIX 4"), onAssistantText never fires,
  // the classifier in main.js never runs — and the audio played anyway. That is
  // how untranslated English reached the customer with nothing in the log.
  //
  // We now tell the handler whether any ASSISTANT text for this turn actually
  // reached it. `vetted: false` means "this audio was never language-checked",
  // and main.js treats it as unsafe rather than playing it blind.
  let turnAssistantTextEmitted = false;

  // Which generation stage the currently open ASSISTANT block belongs to.
  // Nova Sonic emits the same translation once per stage, seconds apart, which
  // is why the UI has to recognise the second copy as a repeat rather than as
  // a new turn. Logged so that spacing stays visible in the console.
  let currentGenerationStage = null;

  // ─── Nova Sonic's documented event fields (fix 4) ─────────────────────────
  // Output events identify a content block by `contentId` (`contentName` exists only on INPUT events),
  // and `completionEnd` arrives once, when the whole session ends. So the contentName-keyed layers and
  // the completionEnd reset in this function never run: the call logs show contentName: "null" and
  // assistantClosedThisTurn: false on every line, and no [completionEnd] at all. The state below uses
  // the documented fields instead: contentId for each block's role, type and generation stage, and
  // contentEnd.stopReason (END_TURN / INTERRUPTED) on the ASSISTANT FINAL text to close a turn.
  const blocksById = new Map(); // contentId -> { role, type, stage }

  // Audio vetting per audio block. Each sentence arrives as SPECULATIVE text, then its audio, then its
  // FINAL text. An audio block counts as vetted when a new SPECULATIVE text went through the classifier
  // since the previous audio block began. (turnAssistantTextEmitted above was set by the first text of
  // the session and never cleared, so after the first sentence it vetted every audio block.)
  let speculativeTextSeq = 0;
  let speculativeSeqAtAudioStart = 0;
  let insideAudioBlock = false;
  let audioBlockVetted = false;
  let audioBlockWarned = false;
  // The first few contentEnd events of each session are logged, to record Nova Sonic's real sequence.
  let contentEndLogsLeft = 12;

  try {
    for await (const event of responseBody) {
      if (sessionState.stopped) break;

      if (event.chunk?.bytes) {
        const textResponse = new TextDecoder().decode(event.chunk.bytes);
        let jsonResponse;
        try {
          jsonResponse = JSON.parse(textResponse);
        } catch {
          continue;
        }
        const ev = jsonResponse.event;
        if (!ev) continue;

        if (ev.contentStart) {
          const contentName = ev.contentStart.contentName;
          const role = ev.contentStart.role || "USER";

          // ── Layer 2: detect brand-new USER block after ASSISTANT closed ──
          // If an ASSISTANT block has already completed this turn and Nova
          // Sonic now opens a new USER block, it is a post-assistant misfire.
          if (role === "USER" && assistantBlockClosedThisTurn) {
            console.warn(
              `${LOGGER_PREFIX} [${sessionLabel}] - [MISFIRE-L2] New USER contentStart after ASSISTANT` +
              ` already closed this turn | contentName: "${contentName}"` +
              ` | assistantBlockClosedThisTurn: true → marking block as misfire`
            );
            currentBlockIsMisfire = true;
          } else {
            currentBlockIsMisfire = false;
          }

          // ── Layer 3: track whether we are inside an ASSISTANT block ───────
          // Used to catch misfires where a textOutput with role="USER" and
          // NO contentName arrives while the current open block is ASSISTANT.
          // Such events bypass Layers 1 & 2 but are structurally impossible
          // as legitimate transcriptions inside an ASSISTANT content block.
          currentlyInsideAssistantBlock = (role === "ASSISTANT");

          // Register this content block's declared role
          if (contentName) {
            contentBlockRoles[contentName] = role;
          }

          // Determine whether to surface assistant text for this block
          displayAssistantText = false;
          currentGenerationStage = null;
          if (role === "ASSISTANT") {
            if (ev.contentStart.additionalModelFields) {
              try {
                const extra = JSON.parse(ev.contentStart.additionalModelFields);
                currentGenerationStage = extra.generationStage ?? null;
                // Show FINAL (matches spoken audio) and SPECULATIVE (draft)
                displayAssistantText =
                  extra.generationStage === "FINAL" ||
                  extra.generationStage === "SPECULATIVE";
              } catch {
                displayAssistantText = false;
              }
            } else {
              // FIX 4: Revert default to false (matches old working code behaviour).
              // The previous default of true caused ALL assistant content blocks
              // (even those without additionalModelFields) to emit text, firing
              // onAssistantText 2-3x per turn and multiplying drift-check
              // false-positive opportunities. Old code (novasonic2.js) never
              // set displayAssistantText=true without an explicit SPECULATIVE
              // generationStage signal — restoring that conservative default.
              displayAssistantText = false;
            }
          }

          // fix 4: remember the block by its real id, and start vetting a new audio block.
          const blockId = ev.contentStart.contentId;
          const blockType = ev.contentStart.type;
          if (blockId) blocksById.set(blockId, { role, type: blockType, stage: currentGenerationStage });
          if (role === "ASSISTANT" && blockType === "AUDIO") {
            insideAudioBlock = true;
            audioBlockVetted = speculativeTextSeq > speculativeSeqAtAudioStart;
            speculativeSeqAtAudioStart = speculativeTextSeq;
            audioBlockWarned = false;
          }

        } else if (ev.contentEnd) {
          // fix 4: close audio blocks and assistant turns using the documented fields.
          const endedId = ev.contentEnd.contentId;
          const ended = endedId ? blocksById.get(endedId) : undefined;
          if (endedId) blocksById.delete(endedId);
          const stopReason = ev.contentEnd.stopReason;
          if (contentEndLogsLeft > 0 || stopReason === "INTERRUPTED") {
            contentEndLogsLeft--;
            console.info(
              `${LOGGER_PREFIX} [${sessionLabel}] - [contentEnd] role: ${ended?.role ?? "?"}` +
              ` | type: ${ended?.type ?? ev.contentEnd.type ?? "?"} | stage: ${ended?.stage ?? "none"}` +
              ` | stopReason: ${stopReason ?? "none"}`
            );
          }
          if (ended?.type === "AUDIO") insideAudioBlock = false;
          if (
            ended?.role === "ASSISTANT" &&
            ended.type === "TEXT" &&
            ended.stage === "FINAL" &&
            (stopReason === "END_TURN" || stopReason === "INTERRUPTED")
          ) {
            console.info(`${LOGGER_PREFIX} [${sessionLabel}] - [turn-end] assistant turn complete | stopReason: ${stopReason}`);
            handlers.onTurnComplete?.(stopReason === "INTERRUPTED");
          }

          const contentName = ev.contentEnd?.contentName;

          // Mark this block as formally closed.
          if (contentName) {
            closedContentBlocks.add(contentName);
            // Track when an ASSISTANT block has fully closed this turn.
            // Any USER block opening after this point is a misfire (Layer 2).
            if (contentBlockRoles[contentName] === "ASSISTANT") {
              assistantBlockClosedThisTurn = true;
            }
          }
          // Block is now closed — reset per-block flags.
          currentBlockIsMisfire = false;
          currentlyInsideAssistantBlock = false;

        } else if (ev.textOutput) {
          const content = ev.textOutput.content || "";
          const contentName = ev.textOutput.contentName;
          const rawRole = ev.textOutput.role || "USER";

          // ── Layer 1: closed-block misfire check ──────────────────────────
          if (contentName && closedContentBlocks.has(contentName)) {
            console.warn(
              `${LOGGER_PREFIX} [${sessionLabel}] - [MISFIRE-L1] Suppressing textOutput | contentName: "${contentName}"` +
              ` | rawRole: ${rawRole} | reason: block already closed | content: "${content.slice(0, 60)}"`
            );
            continue;
          }

          // ── Layer 2: post-assistant USER-block misfire check ─────────────
          if (currentBlockIsMisfire) {
            console.warn(
              `${LOGGER_PREFIX} [${sessionLabel}] - [MISFIRE-L2] Suppressing textOutput | contentName: "${contentName}"` +
              ` | rawRole: ${rawRole} | reason: post-assistant USER block | content: "${content.slice(0, 60)}"`
            );
            continue;
          }

          // ── Layer 3: no-contentName misfire inside ASSISTANT block ────────
          // A textOutput with role="USER", no contentName, arriving while we
          // are currently inside an ASSISTANT block is structurally a misfire.
          // It bypasses Layers 1 & 2 because the block is not yet closed and
          // has no contentName to look up. This is the most common remaining
          // misfire pattern causing translated text to leak into the original
          // speech box.
          if (!contentName && rawRole === "USER" && currentlyInsideAssistantBlock) {
            console.warn(
              `${LOGGER_PREFIX} [${sessionLabel}] - [MISFIRE-L3] Suppressing textOutput | contentName: null` +
              ` | rawRole: USER | reason: no-contentName USER textOutput inside ASSISTANT block` +
              ` | currentlyInsideAssistantBlock: true | content: "${content.slice(0, 60)}"`
            );
            continue;
          }

          // ── Nova Sonic status-string filter ──────────────────────────────
          // Intercept model-internal strings like "Interrupted = true" that
          // Nova Sonic leaks into textOutput on interrupted turns.
          if (isNovaStatusString(content)) {
            console.warn(
              `${LOGGER_PREFIX} [${sessionLabel}] - [STATUS-FILTER] Suppressing Nova Sonic status string` +
              ` | content: "${content}"`
            );
            // Every status string is an interruption notice (barge-in). Counted only: in an
            // interpreter the speaker going on talking is not a reason to drop translation already made.
            handlers.onInterrupted?.();
            continue;
          }

          // ── Role resolution (per-block, not shared variable) ─────────────
          const resolvedRole =
            (contentName && contentBlockRoles[contentName]) ||
            rawRole;

          // ── Layer 4: cross-turn fuzzy match ───────────────────────────
          // Nova Sonic splits one logical exchange into two completionEnd-
          // terminated turns. The misfire USER text arrives in the SECOND
          // turn after completionEnd has already reset Layers 1-3. By the
          // time it arrives, all structural flags look clean.
          // We compare every incoming USER textOutput against the ASSISTANT
          // text from the immediately preceding turn. If the content is
          // the same or highly similar, it is the translated text being
          // re-emitted under the wrong role — suppress it.
          if (resolvedRole === "USER" &&
              crossTurnFuzzyMatch(content, lastAssistantTextAcrossTurns)) {
            console.warn(
              `${LOGGER_PREFIX} [${sessionLabel}] - [MISFIRE-L4] Suppressing cross-turn misfire textOutput` +
              ` | rawRole: ${rawRole} | resolvedRole: ${resolvedRole}` +
              ` | lastAssistantText: "${lastAssistantTextAcrossTurns.slice(0, 60)}"` +
              ` | content: "${content.slice(0, 60)}"`
            );
            // Nova Sonic heard its own previous output (echo). main.js uses this to keep a repeat of
            // that output from being played again.
            handlers.onEchoDetected?.(content);
            continue;
          }

          // ── Diagnostic log — every textOutput that reaches the UI ────────
          // Shows exactly what Nova Sonic sent, how it was resolved, and
          // which handler received it. If translated text still appears in
          // the original speech box, look for [textOutput] lines with
          // resolvedRole: USER and target-language content — that tells you
          // the misfire pattern and what new layer is needed.
          console.info(
            `${LOGGER_PREFIX} [${sessionLabel}] - [textOutput] contentName: "${contentName ?? "null"}"` +
            ` | rawRole: ${rawRole}` +
            ` | resolvedRole: ${resolvedRole}` +
            ` | generationStage: ${currentGenerationStage ?? "none"}` +
            ` | insideAssistantBlock: ${currentlyInsideAssistantBlock}` +
            ` | assistantClosedThisTurn: ${assistantBlockClosedThisTurn}` +
            ` | lastAssistantAcrossTurns: "${lastAssistantTextAcrossTurns.slice(0, 40)}"` +
            ` | → ${resolvedRole === "USER" ? "onUserText" : "onAssistantText"}` +
            ` | content: "${content.slice(0, 60)}${content.length > 60 ? "..." : ""}"`
          );

          // fix 4: judge the text by its own block where the id is known, rather than by whichever
          // block opened last, so an audio block opening in between cannot hide this text.
          const textBlock = ev.textOutput.contentId ? blocksById.get(ev.textOutput.contentId) : undefined;
          const textStage = textBlock ? textBlock.stage : currentGenerationStage;
          const showAssistantText = textBlock
            ? textBlock.role === "ASSISTANT" && (textStage === "FINAL" || textStage === "SPECULATIVE")
            : displayAssistantText;

          if (resolvedRole === "USER") {
            // Layer 5: record every USER text emitted this turn so we can
            // retroactively detect pre-ASSISTANT misfires at completionEnd.
            turnUserTexts.push(content);
            handlers.onUserText?.(content, false);
          } else if (resolvedRole === "ASSISTANT" && showAssistantText) {
            // ── ASSISTANT content sanitizer ─────────────────────────────────
            // Strip any embedded "USER: ...\nASSISTANT: ..." role-label prefixes
            // that Nova Sonic leaks when system-prompt role instructions are
            // misread as text-format directives (Rule 18 backfire).
            // Must run BEFORE lastAssistantTextAcrossTurns is updated so that
            // Layer 4 and Layer 5 never see corrupted role-label content.
            const sanitizedContent = sanitizeAssistantContent(content);
            if (!sanitizedContent) continue; // fully consumed by sanitizer

            // Update cross-turn tracking every time legitimate ASSISTANT text fires.
            // This value persists across completionEnd so Layer 4 can compare
            // the next turn's USER text against this translation.
            lastAssistantTextAcrossTurns = sanitizedContent;
            // Layer 5: record every ASSISTANT text so completionEnd can cross-match.
            turnAssistantTexts.push(sanitizedContent);
            // Mark this turn's audio as language-checked — onAssistantText is
            // where main.js runs the drift/refusal classifier.
            turnAssistantTextEmitted = true;
            // fix 4: a SPECULATIVE text vets the audio block that follows it (or, if it arrives inside
            // an audio block, the rest of that block).
            if (textStage === "SPECULATIVE") {
              speculativeTextSeq++;
              if (insideAudioBlock) {
                audioBlockVetted = true;
                speculativeSeqAtAudioStart = speculativeTextSeq;
              }
            }
            handlers.onAssistantText?.(sanitizedContent, false, { stage: textStage });
          }

        } else if (ev.audioOutput) {
          const b64 = ev.audioOutput.content;
          if (b64) {
            const raw = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
            const wav = pcm16MonoToWavArrayBuffer(raw, NOVA_OUTPUT_SAMPLE_RATE);
            if (!audioBlockVetted && !audioBlockWarned) {
              audioBlockWarned = true;
              console.warn(
                `${LOGGER_PREFIX} [${sessionLabel}] - [AUDIO-UNVETTED] audio block with no new ASSISTANT` +
                ` preview text before it — its audio is held until its text has been checked`
              );
            }
            handlers.onAssistantAudioWav?.(wav, { vetted: audioBlockVetted });
          }
        } else if (ev.completionEnd) {
          // Determine if this turn was interrupted (barge-in / VAD cut-off).
          // Nova Sonic sets interrupted:true and/or stopReason:"interrupted"
          // when it cuts off its own output mid-generation.
          const interrupted =
            ev.completionEnd.interrupted === true ||
            ev.completionEnd.stopReason === "interrupted";

          // ── Layer 5: same-turn pre-ASSISTANT USER misfire retraction ─────────
          //
          // NEW ROOT CAUSE (latest logs):
          //   Nova Sonic emits the translation as USER in CHUNKS/FRAGMENTS before
          //   opening the ASSISTANT block. The chunks are SUBSTRINGS of the full
          //   ASSISTANT text, not equal to it. Example from logs:
          //     USER:      "para autenticarte primero y luego podemos proceder con el"
          //     USER:      "problema"
          //     ASSISTANT: "entendido, así que voy a requerir algunos de tus
          //                  detalles para autenticarte primero y luego podemos
          //                  proceder con el problema"
          //
          //   The old crossTurnFuzzyMatch MISSED these because:
          //     - Containment ratio: 55/120 = 0.45  → below 0.70 threshold
          //     - Jaccard:            9/20  = 0.45  → below 0.55 threshold
          //
          // FIX — Two-pass approach:
          //   Pass 1 (individual): Use sameTurnMisfireMatch (directional
          //     containment + lower Jaccard 0.40) on each USER chunk.
          //   Pass 2 (combined):  Join ALL USER chunks and match the combined
          //     text against ASSISTANT texts. Catches cases where individual
          //     chunks are too short to match but the combination is clearly
          //     a fragment of the translation ("problema" alone → 8 chars,
          //     below 15-char guard, but combined it IS in the ASSISTANT text).
          //   If combined matches → ALL USER texts for this turn are misfires.
          if (turnUserTexts.length > 0 && turnAssistantTexts.length > 0) {
            // Pass 1: individual chunk matching
            const individualMisfires = turnUserTexts.filter((uText) =>
              turnAssistantTexts.some((aText) => sameTurnMisfireMatch(uText, aText))
            );

            // Pass 2: combined text matching
            const combinedUserText = turnUserTexts.join(" ");
            const combinedIsMisfire = turnAssistantTexts.some((aText) =>
              sameTurnMisfireMatch(combinedUserText, aText)
            );

            // If combined text matches → entire USER block this turn is a misfire
            const misfiredUserTexts = combinedIsMisfire
              ? [...turnUserTexts]          // retract all USER chunks
              : individualMisfires;         // retract only individually matched chunks

            if (misfiredUserTexts.length > 0) {
              console.warn(
                `${LOGGER_PREFIX} [${sessionLabel}] - [MISFIRE-L5] Pre-ASSISTANT USER misfires detected` +
                ` at completionEnd | mode: ${combinedIsMisfire ? "COMBINED" : "INDIVIDUAL"}` +
                ` | count: ${misfiredUserTexts.length}` +
                ` | texts: ${JSON.stringify(misfiredUserTexts.map((t) => t.slice(0, 40)))}`
              );
              handlers.onUserTextRetraction?.(misfiredUserTexts);
            }
          }

          // Reset ALL per-turn tracking for next turn.
          closedContentBlocks.clear();
          assistantBlockClosedThisTurn = false;
          currentBlockIsMisfire = false;
          currentlyInsideAssistantBlock = false;
          turnUserTexts   = [];
          turnAssistantTexts = [];
          turnAssistantTextEmitted = false;

          console.info(
            `${LOGGER_PREFIX} [${sessionLabel}] - [completionEnd] turn complete` +
            ` | interrupted: ${interrupted}` +
            ` | resetting all per-turn misfire tracking`
          );

          // Pass interrupted flag so handlers can skip incomplete transcript cards.
          handlers.onTurnComplete?.(interrupted);
        }
      } else {
        // ── Terminal stream exceptions ──────────────────────────────────────
        // Previously only modelStreamErrorException and internalServerException
        // were handled, and neither broke the loop. Two consequences:
        //
        //  1. validationException / throttlingException /
        //     serviceUnavailableException — the shapes AWS returns for idle
        //     session timeouts — fell through silently. No onError, no
        //     reconnect: the session became a zombie and the customer heard
        //     nothing for the rest of the call.
        //  2. Even for the two handled cases the loop continued, so the dead
        //     session kept firing handlers while main.js started a replacement.
        //     Both sessions then wrote audio to the same output.
        //
        // Every one of these is terminal for the stream, so report and stop.
        const terminal =
          event.modelStreamErrorException ||
          event.internalServerException ||
          event.validationException ||
          event.throttlingException ||
          event.serviceUnavailableException;

        if (terminal) {
          const kind =
            (event.modelStreamErrorException && "modelStreamErrorException") ||
            (event.internalServerException && "internalServerException") ||
            (event.validationException && "validationException") ||
            (event.throttlingException && "throttlingException") ||
            "serviceUnavailableException";
          console.error(`${LOGGER_PREFIX} [${sessionLabel}] - Nova Sonic ${kind}`, terminal);
          handlers.onError?.(new Error(terminal.message || kind));
          break;
        }
      }
    }
  } catch (e) {
    if (!sessionState.stopped) {
      console.error(`${LOGGER_PREFIX} - Nova Sonic response stream error`, e);
      handlers.onError?.(e);
    }
  }
}

// Nova Sonic hard session limit is 8 minutes. We proactively restart at 7m30s.
const NOVA_SESSION_MAX_MS = 8 * 60 * 1000;       // 8 minutes (AWS hard limit)
const NOVA_SESSION_RESTART_MS = 7.5 * 60 * 1000; // 7m30s — proactive restart threshold

/**
 * Runs a single Nova Sonic bidirectional interpreter session over a MicrophoneStream (or compatible async iterable).
 * Implements Option 3 session resilience:
 *   - Proactive restart at 7m30s (before AWS 8-min hard limit)
 *   - onSessionExpiring callback so main.js can seamlessly restart
 * @returns {{ stop: () => Promise<void> }}
 */
export async function startNovaSonicInterpreterSession({
  audioStream,
  inputSampleRate,
  sourceLangCode,
  targetLangCode,
  voiceId,
  handlers,
  sessionLabel = "UNKNOWN",
}) {
  // Split the two costs inside this call. The [TIMING] marks in main.js showed
  // session open accounting for ~99% of the Start button, but not whether that
  // is the Cognito credential exchange or the Bedrock stream handshake.
  const tSessionStart = performance.now();
  const openStream = await prepareNovaStream();
  const tClientReady = performance.now();
  const promptName = crypto.randomUUID();
  const textContentName = crypto.randomUUID();
  const audioContentName = crypto.randomUUID();
  // Written in the target language when one is available — see interpreterPrompts.js
  // for why an English prompt demanding non-English output causes drift.
  const systemPrompt = buildInterpreterPrompt(sourceLangCode, targetLangCode, "speech");

  const queue = new NovaOutboundQueue();
  const sessionState = { stopped: false };

  // Proactive restart timer — fires at 7m30s before AWS kills at 8m
  const proactiveRestartTimer = setTimeout(() => {
    if (!sessionState.stopped) {
      console.warn(`${LOGGER_PREFIX} - Nova Sonic session approaching 8-min limit — triggering proactive restart`);
      handlers.onSessionExpiring?.();
    }
  }, NOVA_SESSION_RESTART_MS);

  await enqueueSessionPreamble(queue, {
    voiceId,
    systemPrompt,
    promptName,
    textContentName,
    audioContentName,
  });

  let response;
  try {
    response = await openStream(queue);
  } catch (e) {
    queue.close();
    // The session never started, so it must not trigger a "proactive restart" 7.5 minutes from now.
    clearTimeout(proactiveRestartTimer);
    throw e;
  }
  console.info(
    `${LOGGER_PREFIX} [${sessionLabel}] - [TIMING] ${PROXY_CONFIG.enabled ? "proxy" : "bedrock client + credentials"}: ` +
    `${Math.round(tClientReady - tSessionStart)}ms | stream handshake: ` +
    `${Math.round(performance.now() - tClientReady)}ms`
  );

  const outputTask = processResponseStream(response.body, handlers, sessionState, sessionLabel);

  // One per session: it low-pass filters before converting to 16 kHz and carries its state from chunk
  // to chunk (see createPcm16Downsampler).
  const downsampler = createPcm16Downsampler(inputSampleRate, NOVA_INPUT_SAMPLE_RATE);

  const inputTask = (async () => {
    try {
      for await (const chunk of audioStream) {
        if (sessionState.stopped) break;
        if (chunk.length <= inputSampleRate) {
          const pcm16 = downsampler.process(chunk);
          const b64 = toBase64(pcm16);
          queue.enqueueEvent({
            event: {
              audioInput: {
                promptName,
                contentName: audioContentName,
                content: b64,
              },
            },
          });
        }
      }
    } catch (e) {
      if (!sessionState.stopped) console.error(`${LOGGER_PREFIX} - Nova Sonic audio input loop`, e);
    } finally {
      try {
        queue.enqueueEvent({
          event: {
            contentEnd: {
              promptName,
              contentName: audioContentName,
            },
          },
        });
        await delay(20);
        queue.enqueueEvent({
          event: {
            promptEnd: { promptName },
          },
        });
        await delay(20);
        queue.enqueueEvent({ event: { sessionEnd: {} } });
      } catch {
        /* queue may already be closed */
      }
      queue.close();
    }
  })();

  return {
    stop: async () => {
      sessionState.stopped = true;
      // Clear the proactive restart timer so it does not fire after
      // an intentional stop (e.g. agent clicks Stop, call ends).
      clearTimeout(proactiveRestartTimer);
      await inputTask.catch(() => {});
      await outputTask.catch(() => {});
    },
  };
}

/**
 * Typed agent message: translate to target language and speak via Nova Sonic (no separate Translate/Polly).
 */
export async function runNovaSonicTypedTextInterpretation({ text, sourceLangCode, targetLangCode, voiceId, handlers }) {
  const openStream = await prepareNovaStream();
  const promptName = crypto.randomUUID();
  const textContentName = crypto.randomUUID();
  const userTextContentName = crypto.randomUUID();
  const systemPrompt = buildInterpreterPrompt(sourceLangCode, targetLangCode, "typed");
  const queue = new NovaOutboundQueue();
  const sessionState = { stopped: false };

  await enqueueInterpreterSessionStartAndSystem(queue, {
    voiceId,
    systemPrompt,
    promptName,
    textContentName,
  });
  await enqueueUserTextContentTurn(queue, { promptName, userTextContentName, text });
  queue.enqueueEvent({ event: { promptEnd: { promptName } } });
  await delay(20);
  queue.enqueueEvent({ event: { sessionEnd: {} } });
  await delay(20);
  queue.close();

  const response = await openStream(queue);

  await processResponseStream(response.body, handlers, sessionState, "AGENT-TYPED");
}
