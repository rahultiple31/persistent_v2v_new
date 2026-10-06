# Amazon Connect Voice to Voice (V2V) Translation Setup Guide

This repository uses **Amazon Bedrock Nova Sonic** for bidirectional speech interpretation (replacing separate Amazon Transcribe, Amazon Translate, and Amazon Polly adapters). The webapp invokes the Bedrock runtime with credentials from the Amazon Cognito Identity Pool.

## Table of Contents

- [Solution components](#solution-components)
- [Solution prerequisites](#solution-prerequisites)
- [Solution setup](#solution-setup)
- [Test Webapp locally](#test-webapp-locally)
- [Server-side proxy (no AWS credentials in the browser)](#server-side-proxy-no-aws-credentials-in-the-browser)
- [Clean up](#clean-up)
- [Demo Webapp key components](#demo-webapp-key-components)

## Solution components

On a high level, the solution consists of the following components:

- **webapp** — Demo web application (Vite): Amazon Connect Streams, Connect RTC, Nova Sonic session via `@aws-sdk/client-bedrock-runtime`.
- **cdk-stacks** — AWS CDK v2 app:
  - **Backend stack** (`CdkBackendStack` in `lib/cdk-backend-stack.ts`) — Amazon Cognito (User Pool, app client, hosted UI domain, Identity Pool). Authenticated users receive IAM permissions to invoke Bedrock (`bedrock:InvokeModel`) for Nova Sonic.
  - **Frontend stack** (`CdkFrontendStack` in `lib/cdk-frontend-stack.ts`) — Amazon S3 bucket for static assets, Amazon CloudFront distribution, and a custom resource that writes `frontend-config.js` (runtime config for the browser).

Parameter definitions live in `cdk-stacks/config/config.params.json`. Deployment values are stored under your chosen hierarchy in **AWS Systems Manager Parameter Store** (see `_ssmPathHelp` in that file). You can override the hierarchy with environment variable `SSM_PARAMETERS_HIERARCHY` when running `configure` or CDK commands.

## Solution prerequisites

- AWS account
- [AWS IAM user](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_users_create.html) with permissions to deploy CDK stacks and manage the resources above
- Amazon Connect instance
- [Node.js](https://nodejs.org/) (v20) and npm (v10) on your machine
- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-getting-started.html) v2 installed and configured (`aws configure` or profiles)
- [AWS CDK](https://docs.aws.amazon.com/cdk/v2/guide/getting_started.html) v2 installed (`npm install -g aws-cdk`)
- **Amazon Bedrock**: In the AWS Console, open **Amazon Bedrock** → **Model access** (or **Inference profiles**, depending on console version) and enable access for the **Nova Sonic** model you will use (default in this project: `amazon.nova-2-sonic-v1:0`) in the **same Region** you set for `bedrock-region` (for example `us-east-1`).

## Solution setup

The steps below use the **repository root** as the folder that contains `cdk-stacks` and `webapp`. Replace paths accordingly if your clone directory name differs.

If you use **Git Bash** on Windows for CDK, prefer the `:gitbash` npm scripts where noted (they wrap `cdk` with `winpty` where needed). On PowerShell, try the standard scripts first if `cdk` is on your `PATH`.

These steps assume prerequisites are done and you already have an Amazon Connect instance.

1. Clone this repository to your computer.

2. Check AWS CLI

   - CDK uses your default AWS credentials and Region (or `AWS_PROFILE`).
   - Verify with a simple call, for example: `aws sts get-caller-identity`
   - Confirm Region, for example:  
     `aws ec2 describe-availability-zones --output text --query 'AvailabilityZones[0].[RegionName]'`

3. Install npm packages

   - In a terminal, go to **`<repo-root>/cdk-stacks`**
   - Run: `npm run install:all`  
     This installs dependencies for **webapp** and **cdk-stacks**.

4. Configure CDK / SSM parameters

   - Stay in **`<repo-root>/cdk-stacks`**
   - Full help: `npm run configure:help`
   - Interactive mode (prompts for each value): `npm run configure`  
     You can also pass flags non-interactively; see the help output.

   When prompted, provide at least:

   | Parameter (CLI flag) | Purpose |
   | -------------------- | ------- |
   | `cognito-domain-prefix` | Cognito hosted UI domain prefix (unique, lowercase; pattern described in configure help). Example: your Connect instance alias. |
   | `cognito-callback-urls` | OAuth redirect after login. For first deploy, use `https://localhost:5173` if you will test locally; after CloudFront is ready, update to your CloudFront URL (comma-separated list allowed). |
   | `cognito-logout-urls` | OAuth redirect after logout; same guidance as callback URLs. |
   | `connect-instance-url` | Your Connect instance URL, e.g. `https://<alias>.my.connect.aws` |
   | `connect-instance-region` | Region of the Connect instance, e.g. `us-east-1` |
   | `bedrock-region` | Region where Nova Sonic is enabled and invoked, e.g. `us-east-1` |
   | `nova-sonic-model-id` | Bedrock model ID, default `amazon.nova-2-sonic-v1:0` |

   There are **no** separate Transcribe, Translate, Polly, or CloudFront proxy toggles in this branch—the browser calls Bedrock directly using Cognito Identity credentials.

5. Deploy CDK stacks

   - In **`<repo-root>/cdk-stacks`**, build the webapp assets:  
     `npm run build:webapp`  
     On Windows with Git Bash: `npm run build:webapp:gitbash`  
     Run this whenever you change the webapp before deploy.
   - First time in an account/Region: `cdk bootstrap`
   - Deploy: `npm run cdk:deploy`  
     Git Bash on Windows: `npm run cdk:deploy:gitbash`
   - Wait until stacks finish. Note outputs:
     - From the backend stack: **userPoolId** (and other Cognito-related outputs as needed).
     - From the frontend stack: **webAppURL** (CloudFront URL).

6. Configure Amazon Connect approved origins

   - In the AWS Console: **Amazon Connect** → your instance → **Approved origins**
   - **Add domain**: your CloudFront URL origin, e.g. `https://d111111abcdef8.cloudfront.net` (use your actual distribution domain).

7. Create a Cognito user

   - Use the **User Pool ID** from the deploy output or **Amazon Cognito** in the console.
   - Create a user via the console or CLI, for example:  
     `aws cognito-idp admin-create-user --region <region> --user-pool-id <userPoolId> --username <email> --user-attributes Name=name,Value=<Name> --desired-delivery-mediums EMAIL`
   - The user receives email with a temporary password for first login.

8. Point Cognito callback and logout URLs at production (and optional localhost)

   - In **`<repo-root>/cdk-stacks`**, run `npm run configure` again.
   - Keep existing values where appropriate; set **callback** and **logout** URLs to your CloudFront site URL (and optionally keep `https://localhost:5173` in the comma-separated list for local dev).
   - Redeploy so Cognito app client settings update:  
     `npm run cdk:deploy` (or `npm run cdk:deploy:gitbash` on Windows/Git Bash).

9. Test the deployed app

   - Open **webAppURL** in the browser.
   - Sign in with Cognito (reset password if prompted).
   - If Amazon Connect CCP is not already authenticated, sign in with your Connect agent credentials (demo sample does not federate Cognito with Connect).
   - You should see the CCP and V2V controls. For UI behavior, see **DEMO.md**.

## Test Webapp locally

To change the webapp and test without uploading to S3 every time:

1. Go to **`<repo-root>/cdk-stacks`**
2. Pull runtime config from the deployed bucket: `npm run sync-config`  
   This copies `frontend-config.js` into **`webapp/`** (S3 path uses stack outputs; AWS CLI must be able to read the bucket).
3. Go to **`<repo-root>/webapp`**
4. Start the dev server: `npm run dev`  
   Vite serves over **HTTPS on port 5173** (mkcert/local cert as configured in the project).
5. Open `https://localhost:5173`
6. Add `https://localhost:5173` under Connect **Approved origins** if you have not already (see step 6 above).
7. When ready to publish: from **`cdk-stacks`**, run `npm run build:deploy:all` (or `npm run build:deploy:all:gitbash` on Windows/Git Bash).

## Clean up

1. Destroy stacks: from **`cdk-stacks`**, run `cdk destroy --all` (confirm prompts).
2. Remove SSM parameters written by configure: `npm run configure:delete`

## Demo Webapp key components

- **Adapters**
  - **Nova Sonic adapter** (`webapp/adapters/novaSonicAdapter.js`) — Uses `@aws-sdk/client-bedrock-runtime` with Cognito Identity credentials to run bidirectional interpreter sessions (agent and customer audio paths). Model and Region come from `NOVA_SONIC_CONFIG` in `webapp/config.js` (populated via `window.WebappConfig` from `frontend-config.js`).
- **Utilities**
  - **Mic stream utilities** (`webapp/utils/micStreamUtils.js`) — Microphone capture for Nova Sonic input.
  - **Nova Sonic audio utilities** (`webapp/utils/novaSonicAudioUtils.js`) — PCM/audio helpers for the Bedrock stream.
- **Managers**
  - **Audio stream managers** (`webapp/managers/AudioStreamManager.js`) — Mix and route streams (e.g. what the customer vs. agent hears). `ToCustomerAudioStreamManager` and `ToAgentAudioStreamManager` attach to the respective audio elements.
  - **Session track manager** (`webapp/managers/SessionTrackManager.js`) — Connect WebRTC media track handling via Connect RTC / Streams.
  - **Audio context / input test** — `AudioContextManager`, `InputTestManager` for device checks.

Language choices for the interpreter UI are defined in `NOVA_INTERPRETER_LANGUAGES` in `webapp/constants.js`.
