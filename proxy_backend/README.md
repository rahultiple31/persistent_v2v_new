# V2V proxy

Runs in Fargate behind the internal load balancer. It serves the web app, makes the AWS AI calls with its
own permissions (the ECS task role), and checks every agent's sign-in token. The browser never obtains AWS
credentials.

| Path | Purpose |
|---|---|
| `GET /` and the page's files | The built web app (`WEBAPP_DIR`), and `/frontend-config.js` generated from `WEBAPP_CONFIG` |
| `GET /ws` (WebSocket) | One Nova Sonic or Transcribe stream per connection |
| `POST /api/fallback` | One Translate + Polly request (the backup translation) |
| `GET /api/translation-mode` | The `forceBackupTranslation` switch, as `{"forceBackup": true}` or `false` |
| `GET /api/voicemail?key=<vmx3_recording_key>` | One VMX3 voicemail recording (WAV), read from `VOICEMAIL_BUCKET`; `404 voicemailOff` without it |
| `GET`, `POST /api/test-sign-in` | The temporary test sign-in, only while it is switched on |
| `GET /healthz` | Health check for the load balancer and the container |

WebSocket protocol ([src/server.js](src/server.js)): the first frame is `{"type":"auth","token":"<access token>"}`,
then `{"type":"start","service":"nova"|"transcribe",...}`, then binary frames (Nova Sonic event JSON, or PCM16
audio). The proxy answers `{"type":"ready"}` once AWS has accepted the stream, relays the output, and ends
with `{"type":"end"}` or `{"type":"error",...}`.

## Security

- **Tokens.** Every WebSocket and API request needs an access token from the corporate identity provider,
  checked locally against its signing keys (JWKS): signature, issuer, audience, expiry, a `sub` claim, and the
  group claim when `ALLOWED_GROUPS` is set. The token travels in the first frame or the `Authorization`
  header, never in a URL. The test sign-in's tokens are checked against the test password's key.
- **Permissions.** The task role can call only `bedrock:InvokeModel` on the configured Nova Sonic model, plus
  Transcribe streaming, `translate:TranslateText` and `polly:SynthesizeSpeech` in the configured Region, and
  read the `forceBackupTranslation` parameter and its secrets (the test sign-in password; with `bff` the
  session key and client secret). With voicemail playback: `s3:GetObject` on the recordings bucket's
  `.wav` files only, and `kms:Decrypt` only through S3 (for a bucket with its own KMS key).
- **Voicemail.** The recording's name comes from the page, so only VMX3 names (`YYYY/MM/DD/<contact ID>.wav`)
  are read, and only from the one bucket. Any signed-in agent can play a voicemail whose name they have; every
  read is logged with the user and the name. Recordings are sent with `Cache-Control: no-store`.
- **Input.** Only the Nova Sonic event types the web app sends are accepted, and the model ID comes from the
  configuration, never from the client. WebSocket frames are capped at 256 KB and backup request bodies at
  16 KB. The WebSocket `Origin` must be the site's address.
- **Limits** (per task). 12 connections per user and 2,000 per task; backup requests per user per minute
  (`FALLBACK_REQUESTS_PER_MINUTE`, 150 in the POC); authentication within 10 seconds; an unused socket closes
  after 10 minutes.
- **Errors and logs.** AWS error details that could reveal internals are not sent to the browser. Logs hold
  metadata only (connection IDs, the user's `sub`, durations, byte counts, error names): never tokens,
  transcripts, translations or audio.
- **Container.** Runs as a non-root user on a read-only root filesystem, with production dependencies only.

## Configuration

All set by the CDK stack (`cdk-stacks/lib/private-poc-stack.ts`); listed here for running the proxy yourself.

| Variable | Required | Default |
|---|---|---|
| `BEDROCK_REGION`, `NOVA_MODEL_ID` | yes | |
| `AUTH_MODE` | no | `oidc` (the page signs in); `bff` for the server-side sign-in |
| `OIDC_ISSUER`, `OIDC_AUDIENCE`, `OIDC_JWKS_URI` | `oidc`: for sign-in; without an issuer every token is rejected | |
| `OIDC_GROUP_CLAIM` (the claim listing the user's groups) | when `ALLOWED_GROUPS` is set | |
| `ALLOWED_GROUPS` (comma-separated) | no | any user |
| `SESSION_KEY_SECRET_ID` (Secrets Manager secret: the session cookie key) | `bff` | |
| `OIDC_ISSUER`, `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET_ID` (Secrets Manager secret), `OIDC_REDIRECT_URI` (the site's root), `OIDC_AUTHORIZATION_ENDPOINT`, `OIDC_TOKEN_ENDPOINT`, `OIDC_JWKS_URI` | `bff`: all or none; none means only the test sign-in works | |
| `OIDC_REVOCATION_ENDPOINT`, `OIDC_END_SESSION_ENDPOINT`, `OIDC_USERINFO_ENDPOINT`, `OIDC_POST_LOGOUT_REDIRECT_URI`, `OIDC_SCOPE` | no (`bff`) | none; `OIDC_REDIRECT_URI`; `openid` |
| `SESSION_HOURS`, `SESSION_CHECK_MINUTES`, `SECRETS_REFRESH_MS` | no (`bff`) | `12`, `30`, `300000` |
| `ALLOWED_ORIGINS` (comma-separated) | yes when `NODE_ENV=production` | any origin |
| `WEBAPP_DIR` (the built web app; set by the Dockerfile) | no | no files served |
| `WEBAPP_CONFIG` (JSON object served as `/frontend-config.js`) | when `WEBAPP_DIR` is set | |
| `CONTENT_SECURITY_POLICY`, `CSP_REPORT_ONLY` | no | no policy; report-only |
| `TRANSCRIBE_REGION`, `TRANSLATE_REGION`, `POLLY_REGION` | no | `BEDROCK_REGION` |
| `FORCE_BACKUP_PARAMETER` (Parameter Store name of the backup switch) | no | switch off |
| `TEST_SIGN_IN_SECRET_ID` (Secrets Manager secret: the test sign-in password, 12+ characters, or `off`) | no | no test sign-in |
| `SECRETS_REGION` (Secrets Manager) | no | `AWS_REGION`, else `BEDROCK_REGION` |
| `VOICEMAIL_BUCKET` (the VMX3 recordings bucket), `VOICEMAIL_REGION` | no | no voicemail playback; `AWS_REGION`, else `BEDROCK_REGION` |
| `SSM_REGION` | no | `AWS_REGION`, else `BEDROCK_REGION` |
| `SERVER_TLS` (`self-signed`: HTTPS with a certificate the proxy makes at start-up, so the load balancer reaches the tasks over HTTPS; the stack sets it) | no | `off` (plain HTTP) |
| `PORT`, `LOG_LEVEL` | no | `8080` (`8443` with `SERVER_TLS=self-signed`), `info` |
| `MAX_CONNECTIONS`, `MAX_CONNECTIONS_PER_USER`, `FALLBACK_REQUESTS_PER_MINUTE`, `VOICEMAIL_REQUESTS_PER_MINUTE` | no | `2000`, `12`, `60`, `30` |
| `DRAIN_TIMEOUT_MS`, `HEARTBEAT_INTERVAL_MS`, `AUTH_TIMEOUT_MS` | no | `100000`, `25000`, `10000` |

The two switches (the backup parameter and the test sign-in secret) are read every 30 seconds, so changing them
needs no deployment. With `forceBackupTranslation`
= `true`, new calls start on Transcribe + Translate + Polly and calls in progress move to it within about a
minute.

**Server-side sign-in** (`AUTH_MODE=bff`, `src/sessionAuth.js`), for an identity provider client that has a
secret. The proxy is the OAuth client (the "backend for frontend" pattern of RFC 10017): `/auth/login` sends the
browser to the identity provider (authorization code with PKCE, state and nonce), the answer comes back to the
site's root, and the proxy swaps the code for tokens with the client secret in the `Authorization` header, checks
the ID token (signature, issuer, audience, expiry, nonce) and the group, and sets an encrypted, `HttpOnly`,
`SameSite=Strict` session cookie (`src/session.js`). The browser never sees a token. `/ws` and `/api` accept the
cookie; every fetch must also carry `X-V2V-Request: 1`, which other sites cannot send, and the WebSocket
upgrade's `Origin` is checked. The page asks `/auth/session` every few minutes; every `SESSION_CHECK_MINUTES` the
proxy renews with the refresh token, and the session ends when the identity provider refuses (user disabled,
removed from the group) or after `SESSION_HOURS`. If the identity provider cannot be reached, the session carries
on and the renewal is retried. Calls to the identity provider look up IPv4 addresses only (its DNS answers IPv6
questions with SERVFAIL, which the container's resolver treats as a failed lookup). The client secret and the
session key are read from Secrets Manager every 5 minutes (`src/services/secrets.js`): a new value needs no
restart, and cookies made with the previous session key (`AWSPREVIOUS`) are still accepted. If the secrets cannot
be read at startup, the proxy still starts; sign-in then answers with an error until they can.

## Develop and test

Node.js 20 or later.

```sh
cd proxy
npm ci
npm test            # no AWS access needed
```

Run it locally against real AWS (your AWS profile makes the AWS calls), then run the web app with
`npm run dev` in `webapp`:

```sh
AWS_PROFILE=dev BEDROCK_REGION=us-east-1 NOVA_MODEL_ID=amazon.nova-2-5-sonic \
OIDC_ISSUER=<issuer> OIDC_AUDIENCE=<audience> OIDC_JWKS_URI=<JWKS URL> \
ALLOWED_ORIGINS=https://localhost:5173 npm start
```
