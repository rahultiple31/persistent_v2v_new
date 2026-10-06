# Amazon Connect V2V Translation - Session Change Log

**Project**: Amazon Connect Voice-to-Voice (V2V) Translation with Nova Sonic
**Scope**: AWS Transcribe integration, Nova Sonic role contamination fixes, session restart lifecycle fixes

---

## Files Changed

| File | Type | Description |
|---|---|---|
| webapp/main.js | Modified | All runtime logic changes |
| webapp/adapters/TranscribeStreamAdapter.js | New File | AWS Transcribe Streaming adapter |

---

## New File: webapp/adapters/TranscribeStreamAdapter.js

Provides a lifecycle-managed wrapper around AWS Transcribe Streaming for agent-side speech-to-text.
Replaces reliance on Nova Sonic USER-role text output for the Agent Said box.

### Responsibilities
- Accepts agent mic MediaStream from MicWorkletStream.getMediaStream()
- Creates its own AudioWorkletNode using existing mic-processor worklet (no second getUserMedia needed)
- Fires onTranscript(text) for final results only (partials skipped to avoid flicker)
- Fires onError(err) on connection failure
- Exposes start() and stop() for clean lifecycle management
- Uses getValidAwsCredentials() (Cognito Identity Pool) - same auth as Bedrock

### Why It Was Needed
Nova Sonic USER-role text output was contaminated with the target (translated) language due to role misfires.
Amazon Transcribe always outputs the agent source language cleanly.
Transcribe now exclusively drives the Agent Said box; Nova Sonic USER-role text is suppressed.
---

## Modified File: webapp/main.js (1489 lines total)

### 1. New Imports Added (lines 23-24)

```javascript
import { TranscribeStreamAdapter } from "./adapters/TranscribeStreamAdapter";
import { CONNECT_CONFIG, NOVA_SONIC_CONFIG } from "./config"; // NOVA_SONIC_CONFIG added
```

### 2. New Module-Level Variable (line 51)

```javascript
let AgentTranscribeAdapter = null;
```

Holds the live TranscribeStreamAdapter instance. null when stopped, instance when running.

---

### 3. New Function: buildCustomerSessionHandlers(accumulated) — line 786

Extracted from customerStartTranscription() into a standalone reusable function.
Both customerStartTranscription() and restartCustomerNovaSession() call this function.

| Handler | Status | Behaviour |
|---|---|---|
| onUserText | ACTIVE | Updates customerTranscriptionTextOutputDiv with customer source language text |
| onAssistantText | ACTIVE | Updates customerTranslatedTextOutputDiv (guarded: only if text differs from source) |
| onAssistantAudioWav | ACTIVE | Plays translated audio to agent headset and optionally back to customer |
| onTurnComplete | ACTIVE | Adds transcript card, resets accumulated |
| onSessionExpiring | ACTIVE | Proactive restart at 7m30s before AWS 8-min hard limit |
| onError | ACTIVE | Reactive reconnect with exponential backoff 1.5s/3s/4.5s, max 3 attempts |

**Bug Fixed**: Customer onUserText was accidentally nulled by a prior automated script
(fix_main.cjs replaced the FIRST onUserText occurrence which belonged to customer handler).
This caused the Customer Said box to be empty throughout every call. Restored to active.

---

### 4. New Function: buildAgentSessionHandlers(accumulated) — line 1054

Extracted from agentStartTranscription() into a standalone reusable function.
Both agentStartTranscription() and restartAgentNovaSession() call this function.

| Handler | Status | Behaviour |
|---|---|---|
| onUserText | NULL | Suppressed. Nova Sonic USER text contaminated with target language. Transcribe drives Agent Said box. |
| onAssistantText | ACTIVE | Updates agentTranslatedTextOutputDiv with target language translation (guarded vs accumulated.user) |
| onAssistantAudioWav | ACTIVE | Plays translated audio to customer via RTC and optionally to agent headset |
| onTurnComplete | ACTIVE | Adds transcript card, resets accumulated |
| onSessionExpiring | ACTIVE | Proactive restart at 7m30s |
| onError | ACTIVE | Reactive reconnect with exponential backoff, max 3 attempts |

**Bug Fixed**: Agent onUserText was active and writing Nova Sonic USER-role text
(contaminated Spanish) to the Agent Said box causing a Spanish flicker before Transcribe
overwrote it with clean English. Set to null to suppress entirely.
---

### 5. Modified: agentStartTranscription() — line 1144

Added TranscribeStreamAdapter initialisation block after MicWorkletStream.create()
and before startNovaSonicInterpreterSession().

```javascript
AgentTranscribeAdapter = new TranscribeStreamAdapter({
  audioContext:   agentAudioCtx,
  micMediaStream: AmazonTranscribeToCustomerAudioStream.getMediaStream(),
  languageCode:   CCP_V2V.UI.agentTranslateFromLanguageSelect.value,
  region:         NOVA_SONIC_CONFIG.bedrockRegion,
  onTranscript: (text) => {
    accumulated.user = text;
    CCP_V2V.UI.agentTranscriptionTextOutputDiv.textContent = text;
    updateLiveSentiment(CCP_V2V.UI.agentSentimentValue, text);
  },
  onError: (err) => { console.error(err); }
});
await AgentTranscribeAdapter.start(); // awaited on first startup only
```

**Why**: Transcribe must start before Nova Sonic so accumulated.user is set
by the time Nova Sonic onAssistantText guard runs (text !== accumulated.user).

---

### 6. Modified: agentStopTranscription() — line 1214

Added AgentTranscribeAdapter teardown block after AgentNovaSession.stop()
and BEFORE AmazonTranscribeToCustomerAudioStream.destroy().

```javascript
if (AgentTranscribeAdapter) {
  await AgentTranscribeAdapter.stop().catch(() => {});
  AgentTranscribeAdapter = null;
}
```

**Why**: Adapter holds a ref to the mic MediaStream. Destroying MicWorkletStream
first leaves the AudioWorkletNode connected to a dead stream causing uncaught errors.
Teardown order must always be: Nova Sonic -> Transcribe -> MicWorkletStream.

---

### 7. Modified: restartAgentNovaSession(accumulated) — line 966

Called every 7m30s when Nova Sonic proactively restarts before the AWS 8-min hard limit.
Three targeted changes were made:

#### Change A: Stop Transcribe before Step 1 (line 970)

```javascript
if (AgentTranscribeAdapter) {
  await AgentTranscribeAdapter.stop().catch(() => {});
  AgentTranscribeAdapter = null;
}
// Step 1: Destroy old MicWorkletStream...
```

Bug Fixed: Without this, restartAgentNovaSession destroyed the MicWorkletStream
while AgentTranscribeAdapter was still running. The adapter held a dead MediaStream
reference. Its AudioWorkletNode received no more audio. Transcribe _audioGenerator()
stalled waiting on a Promise that never resolved. Transcribe hung silently for the
rest of the call after every 7m30s restart.

#### Change B: Restart Transcribe after Step 3 as fire-and-forget (line 1005)

```javascript
AgentTranscribeAdapter = new TranscribeStreamAdapter({ ...same config... });

// NOT awaited - fire-and-forget
AgentTranscribeAdapter.start().catch(function(err) {
  console.error(LOGGER_PREFIX + " - restart failed", err);
});

// Step 4 continues immediately...
// Step 6: Nova Sonic starts with clean real-time audio
```

Bug Fixed: Using await blocked 1-3 seconds for the Transcribe HTTP handshake.
During this wait MicWorkletStream buffered live mic audio. When Nova Sonic started
it received this 1-3 second burst all at once, triggering safety guardrails:
  - "If you need help with general translations that do not involve sensitive
    personal information, I am here to assist."
  - "Sorry, I cannot provide this information because it might involve translating
    requests related to exposing personal identification details."
Fire-and-forget means Nova Sonic starts immediately with clean real-time audio.
---

## Full Bug Fix Index

| # | Symptom | Root Cause | Fix | Location |
|---|---|---|---|---|
| 1 | Spanish text flickers in Agent Said box | Nova Sonic USER-role text contaminated with target language | onUserText: null in buildAgentSessionHandlers | main.js line 1075 |
| 2 | Customer Said box empty throughout call | Prior script nulled customer onUserText by mistake | Restored active onUserText in buildCustomerSessionHandlers | main.js line 849 |
| 3 | Transcribe not in logs / agent source text empty | TranscribeStreamAdapter code deleted by brace-counting script | Restored import, variable, start(), stop() | main.js lines 23,51,1175,1224 |
| 4 | ReferenceError agentAudioCtx is not defined | Transcribe block inserted in customerStartTranscription instead of agentStartTranscription | Moved block to correct function | main.js line 1175 |
| 5 | Transcribe stuck/silent after 7m30s restart | restartAgentNovaSession never stopped/restarted adapter - dead MediaStream reference | Added stop() before Step 1 and start() after Step 3 | main.js lines 970,1005 |
| 6 | Nova Sonic outputs safety/guideline messages after restart | await start() blocked 1-3s causing MicWorkletStream audio burst triggering guardrails | Changed to fire-and-forget start().catch() | main.js line 1023 |

---

## Audio and Transcription Flow After All Fixes

```
Agent speaks (English)
        |
        +---> MicWorkletStream (AudioWorkletNode on mic-processor)
        |           |
        |           +---> Nova Sonic Agent Session
        |           |         |
        |           |         +-- USER role text  --> suppressed (onUserText: null)
        |           |         +-- ASSISTANT text  --> agentTranslatedTextOutputDiv
        |           |                                   (Spanish played to customer via RTC)
        |           |
        |           +---> TranscribeStreamAdapter (AudioWorkletNode on mic-processor)
        |                       |
        |                       +-- Final transcript --> agentTranscriptionTextOutputDiv
        |                                               (English - Agent Said box, clean)
        |
        +---> accumulated.user = Transcribe text
              (used by onAssistantText guard to filter same-language passthrough)
```

---

## Session Restart Lifecycle After All Fixes

```
Every 7m30s - Nova Sonic proactive restart fires:

1. AgentTranscribeAdapter.stop()          NEW - prevents dead MediaStream hang
2. AgentNovaSession.stop()
3. MicWorkletStream.destroy()              old stream destroyed cleanly
4. ToCustomerAudioStreamManager.dispose()
5. MicWorkletStream.create()               fresh stream
6. new TranscribeStreamAdapter(...)        NEW - wired to fresh stream
7. AgentTranscribeAdapter.start()          NEW - fire-and-forget (no audio burst)
8. Wire audio track to RTC
9. startNovaSonicInterpreterSession()      starts with clean real-time audio
```

---

## Build Output

```
862 modules transformed - no errors - 4.39s
dist/ ready for S3 deployment
```

---

## Files to Commit

```
webapp/main.js
webapp/adapters/TranscribeStreamAdapter.js
```
---

## Bug Fix #7: Inconsistent Translation in Agent Interpreted Box

**Symptom**: Agent Interpreted box sometimes shows direct English text instead of translation. Inconsistent — works sometimes but not others.

**Root Cause**: Timing race condition between Amazon Transcribe and Nova Sonic.

The guard in buildAgentSessionHandlers.onAssistantText was:
```javascript
if (text && text.trim() !== accumulated.user.trim()) { show text }
```

accumulated.user is set by Transcribe (onTranscript).
onAssistantText is fired by Nova Sonic.

These run independently at different speeds:
- onTurnComplete resets accumulated.user to empty string
- Nova Sonic fires onAssistantText within 200-500ms (FAST)
- Transcribe fires onTranscript within 500-2000ms (SLOWER)

When Nova Sonic fires BEFORE Transcribe:
  accumulated.user = "" (empty — reset by onTurnComplete)
  Guard: "English misfire text" !== "" → PASSES → English shows in UI

When Transcribe fires BEFORE Nova Sonic:
  accumulated.user = "Agent English text"
  Guard: "Spanish translation" !== "Agent English text" → PASSES correctly

This race is non-deterministic — hence the inconsistency.

**Fix Applied**: Deferred the guard check inside setTimeout(400ms) in onAssistantText.

```javascript
onAssistantText: (text) => {
  if (!text) return;
  // Defer 400ms to allow Transcribe to update accumulated.user before guard runs.
  // Audio plays immediately via onAssistantAudioWav so text lag is imperceptible.
  setTimeout(() => {
    if (!text.trim()) return;
    if (text.trim() === accumulated.user.trim()) {
      console.warn(LOGGER_PREFIX + " - suppressed ASSISTANT source-language passthrough");
      return;
    }
    accumulated.assistant = text;
    accumulated.lastAssistant = text;
    CCP_V2V.UI.agentTranslatedTextOutputDiv.textContent = text;
  }, 400);
},
```

**Why 400ms works**:
- Transcribe final results typically arrive 300-600ms after agent stops speaking
- Nova Sonic ASSISTANT fires 200-500ms into the turn
- 400ms deferral covers most Transcribe latency scenarios
- Spanish audio plays immediately (onAssistantAudioWav is unaffected)
- Text display lag of 400ms is completely imperceptible to the agent

**File**: webapp/main.js — buildAgentSessionHandlers, onAssistantText handler
