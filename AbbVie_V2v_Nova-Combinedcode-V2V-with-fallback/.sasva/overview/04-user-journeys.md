# User Journeys

# User Journeys

## 1. Agent First-Time Login Journey

```mermaid
journey
    title Agent First-Time Login
    section Visit App
      Open app URL in browser: 5: Agent
      App checks localStorage for tokens: 3: App
      No tokens found — redirect to Cognito: 3: App
    section Cognito Login
      See Cognito hosted login page: 5: Agent
      Enter email + password: 5: Agent
      Cognito validates credentials: 5: Cognito
      Redirect back to app with auth code: 5: Cognito
    section App Initialises
      Exchange auth code for tokens: 5: App
      Obtain AWS credentials via Identity Pool: 5: App
      Load Amazon Connect CCP: 5: App
      App ready — agent sees CCP + translation UI: 5: Agent
```

---

## 2. Agent Handles a Translated Call

```mermaid
journey
    title Agent Handles a Voice-Translated Call
    section Pre-Call
      Customer calls Connect number: 5: Customer
      Contact routed to agent queue: 5: Connect
      Agent sees incoming call in CCP: 5: Agent
      Agent answers call: 5: Agent
    section Translation Starts
      App reads contact language attributes: 5: App
      Nova Sonic session opened with language pair: 5: App
      Mic + remote audio pipelines start: 5: App
      Agent hears customer in their own language: 5: Agent
      Customer hears agent in their own language: 5: Customer
    section During Call
      Agent speaks — translated to customer language: 5: Nova Sonic
      Customer speaks — translated to agent language: 5: Nova Sonic
      Transcripts appear in real-time UI text boxes: 5: App
      Agent can see both source and translated text: 5: Agent
    section Call Ends
      Agent or customer ends the call: 5: Agent
      Nova Sonic session gracefully closed: 5: App
      Audio pipelines torn down: 5: App
      UI resets to ready state: 5: App
```

---

## 3. Agent Mic Test Journey

```mermaid
journey
    title Agent Tests Microphone Before Call
    section Open Mic Test
      Agent clicks "Test Microphone" button: 5: Agent
      App requests mic permission via getUserMedia: 5: App
      Browser shows permission dialog: 3: Browser
      Agent grants microphone access: 5: Agent
    section During Test
      InputTestManager captures mic audio: 5: App
      Real-time audio level meter shown: 5: App
      Agent speaks into microphone: 5: Agent
      Agent sees level indicator respond: 5: Agent
    section End Test
      Agent clicks "Stop Test": 5: Agent
      Mic stream stopped and released: 5: App
      Agent confident mic is working: 5: Agent
```

---

## 4. Token / Session Expiry & Auto-Refresh Journey

```mermaid
journey
    title Automatic Token and Credential Refresh
    section Background Refresh
      Token expiry timer fires (4 min before expiry): 5: App
      App calls Cognito /oauth2/token with refresh_token: 5: App
      New id_token and access_token stored: 5: App
    section Credential Refresh
      AWS credential expiry timer fires (15 min before): 5: App
      App re-federates with new id_token: 5: App
      New STS credentials stored in localStorage: 5: App
      Agent unaware — no interruption to call: 5: Agent
    section Refresh Failure
      Refresh token expired or revoked: 3: App
      App clears localStorage: 3: App
      Agent redirected to Cognito login: 3: App
      Agent logs in again: 3: Agent
```

---

## 5. Language Selection Journey

```mermaid
journey
    title Agent Selects Translation Language Pair
    section Before Call
      Agent sees language dropdowns in UI: 5: Agent
      Agent selects "Agent Language" (e.g. English): 5: Agent
      Agent selects "Customer Language" (e.g. Spanish): 5: Agent
    section Language Applied
      Language pair passed to Nova Sonic session start: 5: App
      System prompt built with source + target languages: 5: App
      Nova Sonic translates in correct direction: 5: Nova Sonic
    section Mid-Call Language Change
      Agent realises language pair is wrong: 3: Agent
      Agent stops translation session: 3: Agent
      Agent changes language dropdowns: 3: Agent
      Agent restarts translation session: 3: App
      New Nova Sonic session opened with correct pair: 5: App
```
