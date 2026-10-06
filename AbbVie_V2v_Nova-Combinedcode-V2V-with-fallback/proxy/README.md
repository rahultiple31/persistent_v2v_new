# V2V server-side proxy

Keeps the AWS permissions on the server, so the Webapp never obtains AWS credentials. The Webapp streams Nova Sonic and Transcribe over a WebSocket and calls the Translate + Polly fallback over HTTPS; the proxy makes the AWS calls with its ECS task role.

Enabled with the `proxy-enabled` deployment parameter (see [SETUP.md](../SETUP.md)). When it is `false`, the Webapp calls AWS directly, as before.

## Architecture

```
browser ──HTTPS / WSS──▶ CloudFront ──VPC origin (AWS network)──▶ internal ALB ──▶ Fargate tasks ──▶ Bedrock / Transcribe / Translate / Polly
           /ws, /api/*    (same distribution as the Webapp)          (private subnets)   (task role)
```

| Path | Purpose |
|---|---|
| `GET /ws` (WebSocket) | One Nova Sonic or Transcribe stream per connection |
| `POST /api/fallback` | Translate + Polly fallback |
| `GET /api/translation-mode` | The `forceBackupTranslation` switch, as `{"forceBackup": true}` or `false` |
| `GET /healthz` | Load balancer and container health check (not routed through CloudFront) |

WebSocket protocol, in [src/server.js](src/server.js): the first frame is `{"type":"auth","token":"<Cognito access token>"}`, then `{"type":"start","service":"nova"|"transcribe",...}`, then binary frames (Nova Sonic event JSON, or PCM16 audio). The server answers `{"type":"ready"}` once AWS has accepted the stream, relays output, and ends with `{"type":"end"}` or `{"type":"error",...}`.

## Latency

The proxy runs in the Bedrock Region and is reached through CloudFront, so it replaces the browser → AWS hop rather than adding one. The agent connects to the nearest CloudFront edge, and the rest of the path is on the AWS network.

- **Pre-opened sockets.** The Webapp keeps 3 authenticated WebSockets open (the customer and agent Nova Sonic sessions and the agent's Transcribe stream start together), so Start does not wait for a TCP + TLS + WebSocket handshake.
- **No authentication round trip.** The client sends `auth`, `start` and its first audio back to back; the proxy queues frames while it verifies the token (locally, against cached signing keys) and replays them in order.
- **No credential exchange.** The Cognito Identity Pool exchange (two AWS calls) no longer runs when Start is pressed.
- **Warm connections to Bedrock.** Nova Sonic streams are multiplexed over warm HTTP/2 connections (the SDK default opens a new connection per stream).
- **Pass-through relaying.** Nova Sonic events are forwarded as the original bytes in both directions; nothing is re-serialised. WebSocket compression is off (audio does not compress), and logging never blocks the event loop.
- **Smaller Webapp bundle.** The AWS SDK is loaded only in direct mode (main bundle 1.27 MB → 0.94 MB).

Measure it with the benchmark below rather than taking this on trust.

## Security controls

- **Credentials.** No AWS credentials reach the browser, and the Cognito identity pool role has no permissions when the proxy is enabled. The task role can call only `bedrock:InvokeModel` on the configured Nova Sonic model, plus Transcribe streaming, `translate:TranslateText` and `polly:SynthesizeSpeech`, each limited to its configured Region.
- **Authentication.** Every WebSocket and API request needs a valid Cognito access token for this app client. The token's signature, issuer, expiry, `token_use` and `client_id` are checked, and optionally `cognito:groups` (the `proxy-allowed-groups` parameter). The token is sent in the first frame or the `Authorization` header, never in a URL, so it does not appear in access logs.
- **Network.** The load balancer is internal, with no public address. CloudFront (VPC origin) is the only way in: its security group admits only the CloudFront origin-facing prefix list, and the tasks admit only the load balancer and can only make outbound HTTPS calls.
- **Input validation.**
  - Only the 8 Nova Sonic event types the Webapp sends are accepted.
  - The model ID comes from server configuration, never from the client.
  - Transcribe language code and sample rate, PCM chunk shape, and fallback text length, language codes, voice and engine are all validated.
  - Frames are capped at 256 KB and request bodies at 16 KB.
  - The WebSocket `Origin` header must match the app's URLs.
- **Abuse limits** (per task).
  - 12 connections per user and 2,000 per task.
  - 60 fallback requests per user per minute.
  - Authentication must complete within 10 seconds.
  - An unused socket closes after 10 minutes.
  - Maximum session lengths: 9 minutes for Nova Sonic, 4 hours for Transcribe.
- **Error handling.** AWS error messages that could reveal internals (for example `AccessDenied`, which names the role and account) are replaced with a generic message. The full error is logged server-side.
- **Logging.** CloudWatch logs are JSON with metadata only: connection IDs, the user's `sub`, durations, byte counts and error names. Tokens, transcripts, translations and audio are never logged. VPC flow logs and load balancer access logs are enabled.
- **Container.**
  - Runs as a non-root user with a read-only root filesystem, with an init process for signal handling.
  - Production dependencies only, with pinned versions (`npm audit`: 0 vulnerabilities).
  - Pin the base image by digest for fully reproducible builds.
- **Availability.**
  - 2 to 10 ARM64 tasks across 2 Availability Zones, scaling on CPU.
  - Rolling deployments with circuit-breaker rollback.
  - On shutdown the proxy fails its health check, moves idle sockets to other tasks at once, and gives active sessions time to finish.
  - The target group waits 8 minutes before removing a task, so every Nova Sonic session reaches its regular 7.5-minute restart on a healthy task.
  - The Webapp reconnects Transcribe automatically if its stream is closed.

Known trade-offs:
- CloudFront → load balancer is HTTP inside the VPC origin's private connection. HTTPS on that hop needs a custom domain and certificate on the load balancer.
- Limits are per task, not global.
- There is no AWS WAF on the distribution. Adding one (it must be created in us-east-1) with rate-based rules is a recommended next step.

## Configuration

Set by CDK from the deployment parameters; listed here for running the proxy yourself.

| Variable | Required | Default |
|---|---|---|
| `COGNITO_USER_POOL_ID`, `COGNITO_CLIENT_ID` | yes | |
| `BEDROCK_REGION`, `NOVA_MODEL_ID` | yes | |
| `TRANSCRIBE_REGION`, `TRANSLATE_REGION`, `POLLY_REGION` | no | `BEDROCK_REGION` |
| `ALLOWED_ORIGINS` (comma-separated) | yes when `NODE_ENV=production` | any origin |
| `ALLOWED_GROUPS` (comma-separated) | no | any user of the pool |
| `PORT` | no | `8080` |
| `MAX_CONNECTIONS`, `MAX_CONNECTIONS_PER_USER`, `FALLBACK_REQUESTS_PER_MINUTE` | no | `2000`, `12`, `60` |
| `DRAIN_TIMEOUT_MS`, `HEARTBEAT_INTERVAL_MS`, `AUTH_TIMEOUT_MS` | no | `100000`, `25000`, `10000` |
| `LOG_LEVEL` | no | `info` |
| `FORCE_BACKUP_PARAMETER` (Parameter Store name of the switch) | no | switch off |
| `SSM_REGION`, `TRANSLATION_MODE_REFRESH_MS` | no | `AWS_REGION` else `BEDROCK_REGION`, `30000` |

**Backup translation switch.** CDK sets `FORCE_BACKUP_PARAMETER` to `<hierarchy>forceBackupTranslation` (for Dev: `/Abbvie/NovaSonic/Dev/forceBackupTranslation`) and allows the task role `ssm:GetParameter` on that one parameter. The proxy reads it every 30 seconds; the webapp asks for it every 30 seconds. With the value `true`, new calls are translated by Transcribe + Translate + Polly instead of Nova Sonic, and calls in progress switch within about a minute; any other value, or no parameter, means Nova Sonic. It is not part of `npm run configure`, so a configure run never resets it, and changing it needs no deployment:

```
aws ssm put-parameter --name /Abbvie/NovaSonic/Dev/forceBackupTranslation --type String --value true --overwrite
aws ssm put-parameter --name /Abbvie/NovaSonic/Dev/forceBackupTranslation --type String --value false --overwrite
```

**Availability Zones (us-east-1).** CloudFront VPC origins do not support AZ ID `use1-az3`, and AZ names map to different AZ IDs in each account. Find yours with `aws ec2 describe-availability-zones --region us-east-1 --query "AvailabilityZones[].[ZoneName,ZoneId]"` and set `proxy-availability-zones` to two names that are not `use1-az3`.

## Develop and test

Node.js 20 or later.

```bash
cd proxy
npm ci
npm test            # unit + integration tests, no AWS access needed
```

Run the proxy locally against real AWS (uses your AWS profile for the AWS calls):

```bash
AWS_PROFILE=dev COGNITO_USER_POOL_ID=us-east-1_xxxx COGNITO_CLIENT_ID=xxxx \
BEDROCK_REGION=us-east-1 NOVA_MODEL_ID=amazon.nova-2-sonic-v1:0 \
ALLOWED_ORIGINS=https://localhost:5173 npm start
```

Then run the Webapp with `npm run dev` in `webapp` and `proxyEnabled: "true"` and `translationEnabled: "true"` in `webapp/frontend-config.js`. The Vite dev server forwards `/ws` and `/api` to `http://localhost:8080` (override with `V2V_PROXY_TARGET`).

## Latency benchmark

[bench/latency.mjs](bench/latency.mjs) streams the same speech in real time through both paths and reports median and p90 values:

- time for the stream to be accepted, which is what the agent waits for after pressing Start
- time from the end of speech to the first translated audio
- time from the end of speech to the first final transcript

```bash
cd proxy
AWS_PROFILE=dev PROXY_TOKEN=<access token> npm run bench -- --proxy-url https://dxxxx.cloudfront.net --runs 10
```

- `AWS_PROFILE` is used for the direct path and to synthesise the test phrase with Polly. Pass `--audio file.raw` (PCM16 LE mono 16 kHz) to use your own recording instead.
- `PROXY_TOKEN` is a Cognito access token for a test user. Open DevTools → Network (with Preserve log on), then sign in to the Webapp or reload it: the `token` request to the Cognito domain → Response → `access_token`. It is valid for 20 minutes.
- Options: `--paths direct,proxy`, `--services nova,transcribe`, `--origin` (defaults to the proxy URL's origin).

Run it from where the agents are. Latency from an office on another continent differs from latency in a lab. The direct path in the benchmark uses fixed credentials, so it leaves out the Cognito credential exchange that the browser pays in direct mode, which favours the direct path.
