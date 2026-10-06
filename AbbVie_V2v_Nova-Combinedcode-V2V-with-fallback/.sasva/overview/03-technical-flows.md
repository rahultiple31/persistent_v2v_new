# Technical Flows

# Technical Flows

## 1. Authentication Flow (OAuth2 + Cognito Identity Federation)

```mermaid
sequenceDiagram
    participant Agent as Agent Browser
    participant App as V2V App (authUtility.js)
    participant LS as localStorage
    participant Cognito as Cognito Hosted UI
    participant STS as STS / Identity Pool

    Agent->>App: Page load
    App->>LS: Check idToken, accessToken, tokenExpiry
    alt Tokens missing or expired
        App->>LS: Save current path as pre_auth_path
        App->>Cognito: Redirect to /oauth2/authorize\n(response_type=code, PKCE)
        Cognito-->>Agent: Login page
        Agent->>Cognito: Enter credentials
        Cognito-->>App: Redirect back with ?code=AUTH_CODE
        App->>Cognito: POST /oauth2/token\n(code + code_verifier)
        Cognito-->>App: {id_token, access_token, refresh_token}
        App->>LS: Store tokens + expiry timestamp
    end
    App->>STS: GetCredentialsForIdentity\n(IdentityPoolId + id_token)
    STS-->>App: {accessKeyId, secretAccessKey, sessionToken, expiration}
    App->>LS: Store awsCredentials
    App->>App: Schedule token refresh (expiry - 4 min)
    App->>App: Schedule credential refresh (expiry - 15 min)
    App->>Agent: App ready
```

---

## 2. Nova Sonic Session Lifecycle

```mermaid
sequenceDiagram
    participant UI as main.js (UI)
    participant NSA as NovaSonicAdapter
    participant ASM as AudioStreamManager
    participant MWS as MicWorkletStream
    participant RWS as RemoteStreamWorkletStream
    participant BR as Bedrock Nova Sonic

    UI->>NSA: startSession(agentLang, customerLang, credentials)
    NSA->>BR: InvokeModelWithBidirectionalStream (open connection)
    NSA->>BR: Send sessionStart event\n(system prompt with language pair)
    NSA->>BR: Send promptStart event
    NSA->>BR: Send contentBlockStart (audio)

    UI->>ASM: startMicrophone(audioContext)
    ASM->>MWS: MicWorkletStream.create(audioContext, constraints)
    MWS-->>ASM: stream ready

    UI->>ASM: captureFromCustomerAudioStream(remoteStream, audioContext)
    ASM->>RWS: RemoteStreamWorkletStream.create(audioContext, remoteStream)
    RWS-->>ASM: stream ready

    loop Agent mic audio loop
        MWS-->>NSA: Float32Array chunk (4096 frames)
        NSA->>NSA: float32ToPcm16 + resample to 16kHz
        NSA->>BR: audioInput event (Base64 PCM16)
    end

    loop Customer remote audio loop
        RWS-->>NSA: Float32Array chunk (4096 frames)
        NSA->>NSA: float32ToPcm16 + resample to 16kHz
        NSA->>BR: audioInput event (Base64 PCM16)
    end

    loop Nova Sonic response stream
        BR-->>NSA: transcript event (text)
        NSA-->>UI: onTranscript callback → update text box
        BR-->>NSA: audioOutput event (Base64 PCM16)
        NSA->>NSA: pcm16MonoToWavArrayBuffer()
        NSA->>NSA: AudioContext.decodeAudioData()
        NSA->>NSA: BufferSourceNode.start() → play translated audio
    end

    UI->>NSA: stopSession()
    NSA->>BR: Send contentBlockStop event
    NSA->>BR: Send promptStop event
    NSA->>BR: Send sessionStop event
    NSA->>ASM: destroy MicWorkletStream
    NSA->>ASM: destroy RemoteStreamWorkletStream
    NSA-->>UI: session ended
```

---

## 3. Amazon Connect Call Integration Flow

```mermaid
sequenceDiagram
    participant CCP as Connect CCP (iframe)
    participant Streams as connect.Streams API
    participant Main as main.js
    participant NSA as NovaSonicAdapter
    participant RTC as Connect RTC Library

    Main->>Streams: connect.core.initCCP(ccpUrl, options)
    Streams-->>Main: CCP initialised

    Main->>Streams: connect.contact.subscribe(onContact)
    Note over Main: Waiting for inbound/outbound call

    CCP-->>Streams: Contact CONNECTED event
    Streams-->>Main: contact.onConnected callback
    Main->>Main: Extract agentLanguage, customerLanguage\nfrom contact attributes
    Main->>NSA: startSession(agentLang, customerLang, awsCreds)

    CCP-->>Streams: Remote audio track available
    Streams-->>RTC: getRemoteAudioStream()
    RTC-->>Main: MediaStream (customer voice)
    Main->>NSA: setRemoteAudioStream(mediaStream)

    Note over NSA: Both audio pipelines now running

    CCP-->>Streams: Contact ENDED / DESTROYED event
    Streams-->>Main: contact.onEnded callback
    Main->>NSA: stopSession()
    Main->>Main: Reset UI state
```

---

## 4. AudioWorklet Pipeline (Off-Main-Thread Audio Capture)

```mermaid
sequenceDiagram
    participant Main as Main Thread
    participant AWS as AudioWorkletNode\n(mic-processor.js)
    participant AWR as AudioWorkletNode\n(remote-stream-processor.js)
    participant AT as Audio Thread

    Main->>Main: audioContext.audioWorklet.addModule(mic-processor.js)
    Main->>Main: audioContext.audioWorklet.addModule(remote-stream-processor.js)

    Main->>AT: new AudioWorkletNode("mic-processor", {bufferSize: 4096})
    Main->>AT: micSource.connect(workletNode)

    loop Every ~256ms (4096 frames @ 16kHz)
        AT->>AT: process(inputs) — accumulate Float32 samples
        AT->>AT: buffer full → this.port.postMessage({audioChunk})
        AT-->>Main: MessagePort message
        Main->>Main: MicWorkletStream._queue.push(chunk)
        Main->>Main: Iterator resolves next() → chunk consumed by NSA
    end

    Main->>AT: workletNode.port.close()
    Main->>AT: workletNode.disconnect()
    Main->>AT: sourceNode.disconnect()
    Main->>Main: mediaStream.getTracks().forEach(t => t.stop())
```

---

## 5. Frontend Config Injection Flow (CDK Deploy)

```mermaid
sequenceDiagram
    participant Dev as Developer
    participant CDK as CDK CLI
    participant CF as CloudFormation
    participant Lambda as FrontendConfig Lambda (Python)
    participant S3 as S3 Bucket

    Dev->>CDK: cdk deploy
    CDK->>CF: Create/Update CdkBackendStack
    CF->>CF: Create CognitoStack → outputs\n(userPoolId, identityPoolId, etc.)
    CF->>Lambda: Invoke Custom Resource (Create)\nProperties: {BucketName, Content, ObjectKey}
    Lambda->>Lambda: Write frontend-config.js\n(window.WebappConfig = {...})
    Lambda->>Lambda: Zip into frontend-config.zip
    Lambda->>S3: Upload .zip → WebAppStaging/frontend-config.zip
    Lambda->>S3: Upload .js → WebAppRoot/frontend-config.js
    Lambda-->>CF: CFN_SUCCESS response
    CF->>S3: BucketDeployment: webapp/dist/* + merge frontend-config.zip
    CDK-->>Dev: Deploy complete
```
