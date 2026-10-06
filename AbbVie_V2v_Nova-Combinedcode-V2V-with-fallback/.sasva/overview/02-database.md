# Database & Data Structure

# Data Storage & State Management

> This project has **no traditional database**. State is managed across three tiers: browser memory (runtime), browser localStorage (session persistence), and AWS SSM Parameter Store (infrastructure config).

---

## State Storage Map

```mermaid
graph TD
    subgraph Browser_Memory["Browser Memory (Runtime — lost on refresh)"]
        NS_SESSION["Nova Sonic Session\n- sessionId\n- streamPromise\n- audioQueue\n- isStreaming flag"]
        AUDIO_CTX["AudioContext\n- shared singleton\n- sampleRate"]
        MEDIA_STREAMS["MediaStreams\n- mic MediaStream\n- remote MediaStream"]
        WORKLETS["AudioWorklet nodes\n- MicWorkletStream\n- RemoteStreamWorkletStream"]
        CALL_STATE["Call State\n- currentContact\n- agentLanguage\n- customerLanguage\n- isTranslating flag"]
        REFRESH_TIMERS["Refresh Timers\n- tokenRefreshTimer\n- credentialRefreshTimer"]
    end

    subgraph LocalStorage["Browser localStorage (Persisted across refresh)"]
        ID_TOKEN["idToken"]
        ACCESS_TOKEN["accessToken"]
        REFRESH_TOKEN["refreshToken"]
        TOKEN_EXPIRY["tokenExpiry (timestamp)"]
        AWS_CREDS["awsCredentials\n{accessKeyId, secretAccessKey,\nsessionToken, expiration}"]
        REDIRECT_URI["pre_auth_path (redirect after login)"]
    end

    subgraph SSM["AWS SSM Parameter Store (Infrastructure)"]
        SSM_COGNITO["cognitoDomainPrefix"]
        SSM_CALLBACK["cognitoCallbackUrls"]
        SSM_LOGOUT["cognitoLogoutUrls"]
        SSM_CONNECT_URL["connectInstanceURL"]
        SSM_CONNECT_REG["connectInstanceRegion"]
        SSM_BEDROCK_REG["bedrockRegion"]
        SSM_MODEL["novaSonicModelId"]
        SSM_STACK_NAME["CdkBackendStackName (output)"]
    end

    subgraph S3_Config["Amazon S3 (Static Assets + Runtime Config)"]
        FRONTEND_CFG["frontend-config.js\nwindow.WebappConfig = {...}\n(injected at deploy time)"]
        WEBAPP["webapp/dist/*\n(HTML, JS, CSS, worklets)"]
    end
```

---

## Data Flow: Configuration Loading

```mermaid
sequenceDiagram
    participant CDK as CDK Deploy
    participant SSM as SSM Parameter Store
    participant Lambda as FrontendConfig Lambda
    participant S3 as S3 Bucket
    participant Browser as Agent Browser

    CDK->>SSM: Read parameters (cognitoDomainPrefix, connectInstanceURL, etc.)
    CDK->>Lambda: Invoke Custom Resource (Create/Update)
    Lambda->>S3: Write frontend-config.js\n(window.WebappConfig = {...})
    Lambda->>S3: Write frontend-config.zip (staging)
    CDK->>S3: Deploy webapp/dist/* (BucketDeployment)
    CDK->>S3: Merge frontend-config.zip into WebAppRoot/
    Browser->>S3: GET index.html + frontend-config.js
    Browser->>Browser: window.WebappConfig loaded\n(Cognito, Connect, Bedrock settings)
```

---

## Data Flow: Token & Credential Lifecycle

```mermaid
stateDiagram-v2
    [*] --> CheckLocalStorage: Page Load
    CheckLocalStorage --> RedirectToCognito: No tokens / expired
    CheckLocalStorage --> ValidateCredentials: Tokens found
    RedirectToCognito --> ExchangeCode: Cognito redirects back with ?code=
    ExchangeCode --> StoreTokens: POST /oauth2/token
    StoreTokens --> FederateCredentials: Store in localStorage
    FederateCredentials --> Ready: Cognito Identity → STS AssumeRoleWithWebIdentity
    ValidateCredentials --> FederateCredentials: Tokens valid, refresh AWS creds
    Ready --> TokenRefresh: Timer fires (expiry - 4 min)
    Ready --> CredentialRefresh: Timer fires (expiry - 15 min)
    TokenRefresh --> StoreTokens: Use refresh_token → new tokens
    CredentialRefresh --> FederateCredentials: Re-federate with fresh tokens
    Ready --> [*]: Page closed / logout
```

---

## Key Data Structures

### `window.WebappConfig` (injected at deploy)
```json
{
  "backendRegion": "us-east-1",
  "identityPoolId": "us-east-1:xxxxxxxx-...",
  "userPoolId": "us-east-1_XXXXXXX",
  "userPoolWebClientId": "xxxxxxxxxxxxxxxxxx",
  "cognitoDomainURL": "https://prefix.auth.us-east-1.amazoncognito.com",
  "connectInstanceURL": "https://alias.my.connect.aws",
  "connectInstanceRegion": "us-east-1",
  "bedrockRegion": "us-east-1",
  "novaSonicModelId": "amazon.nova-2-sonic-v1:0"
}
```

### Nova Sonic Session Event (sent to Bedrock)
```json
{
  "sessionStart": {
    "inferenceConfiguration": { "maxTokens": 1024, "temperature": 0.7 },
    "systemPrompt": "You are a real-time interpreter...",
    "audioInputConfiguration": { "mediaType": "audio/lpcm", "sampleRateHertz": 16000 },
    "audioOutputConfiguration": { "mediaType": "audio/lpcm", "sampleRateHertz": 16000 }
  }
}
```

### AWS Credential Object (localStorage)
```json
{
  "accessKeyId": "ASIA...",
  "secretAccessKey": "...",
  "sessionToken": "...",
  "expiration": "2025-01-01T12:00:00.000Z"
}
```
