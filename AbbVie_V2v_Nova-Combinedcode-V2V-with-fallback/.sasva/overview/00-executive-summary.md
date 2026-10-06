# Executive Summary

# Executive Summary

## Project: Amazon Connect Voice-to-Voice (V2V) Translation
> Customer-branded as **AbbvieNovaSonicV2V**

This solution enables **real-time, bidirectional voice-to-voice language translation** between Amazon Connect contact-centre agents and customers who speak different languages. It is built entirely on AWS managed services with no traditional backend server — the browser calls Amazon Bedrock directly using short-lived federated AWS credentials.

---

## Key Metrics

| Metric | Value |
|---|---|
| Total source files analysed | 25 |
| Lines of code (approx.) | ~4,500 |
| Frontend language | JavaScript (ES Modules) |
| Infrastructure language | TypeScript (AWS CDK v2) |
| Lambda language | Python 3.11 |
| Audio buffer size | 4 096 frames (~256 ms @ 16 kHz) |
| Token auto-refresh buffer | 4 minutes before expiry |
| AWS credential refresh buffer | 15 minutes before expiry |
| CDK stacks | 2 root + 3 nested |

---

## Technology Stack

| Layer | Technology |
|---|---|
| **AI / Speech** | Amazon Bedrock Nova Sonic (`amazon.nova-2-sonic-v1:0`) |
| **Contact Centre** | Amazon Connect Streams API + Connect RTC v1.1.26 |
| **Auth** | AWS Cognito User Pool + Identity Pool (OAuth 2.0 PKCE-style) |
| **Frontend build** | Vite + node-polyfills + mkcert (HTTPS dev) |
| **Audio pipeline** | Web Audio API — AudioWorkletNode (off-main-thread) |
| **Infrastructure** | AWS CDK v2 (TypeScript) |
| **Config injection** | CloudFormation Custom Resource (Python Lambda → S3) |
| **Static hosting** | Amazon S3 (+ CloudFront implied) |
| **Parameter store** | AWS SSM Parameter Store |

---

## What Makes This Solution Unique

1. **No backend proxy** — Browsers obtain temporary AWS credentials directly from Cognito Identity Pool and invoke Bedrock Nova Sonic's bidirectional streaming API (`InvokeModelWithBidirectionalStream`) without a server in the middle.

2. **Dual-stream audio architecture** — Two independent AudioWorklet pipelines run concurrently: one for the agent's microphone and one for the customer's WebRTC remote audio. Both streams are fed into Nova Sonic simultaneously.

3. **AudioWorklet migration** — The codebase explicitly migrated away from the deprecated `ScriptProcessorNode` (used internally by the `microphone-stream` npm package) to `AudioWorkletNode`. This fixed a critical production bug where irregular chunk sizes on the main thread caused Nova Sonic to misassign USER/ASSISTANT speech roles, displaying translated text in the wrong text box.

4. **Zero-server deployment** — Static assets hosted on S3; runtime config injected at deploy time via a CDK Custom Resource Lambda so no environment-specific build is needed.
