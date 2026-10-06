# Deploy Nova V2V

Both `dev` and `dev-nsso` deploy in `us-east-1`. Each environment keeps
separate `proxy` and `v2v` Terraform states, Cognito pools, buckets, ECR
repositories, and proxy networks. The Connect instance URLs in each
`terraform.tfvars` are preserved.

## First deployment

Repeat these steps for each environment:

1. Run `azure-pipelines.yml` with `targetEnvironment=dev` or `dev-nsso`,
   `targetModule=proxy`, and `terraformAction=apply`. This provisions the
   network, internal ALB, ECR, and a health-only ECS bootstrap service.
2. Run the same pipeline with `targetModule=v2v` and
   `terraformAction=apply`. The V2V state reads the matching proxy state's ALB,
   creates Cognito and CloudFront, writes `window.WebappConfig`, builds the
   webapp, and uploads its assets. Translation is not operational until step 3.
3. Run `proxy_backend/CICD/azure-cicd.yml` for the same environment with
   `terraformAction=apply`. It tests the proxy, builds an immutable ARM64 ECR
   image, and plans/applies the proxy state with `proxy_runtime_enabled=true`.
   The proxy reads Cognito IDs and the application origin from the V2V state.
   Terraform removes the bootstrap command and waits for healthy ECS tasks.

Both pipelines default to `plan`; select `apply` to deploy. Apply jobs use
the matching Azure DevOps approval environment. Main infrastructure pipeline
updates preserve an already activated proxy image and runtime setting.
Re-run the proxy deployment after changes to Cognito, allowed groups/origins,
or runtime settings. Do not run a `proxy` plan against the `v2v` state, or
combine existing separately owned resources into another state.

## State and permissions

The state bucket is `bts-cloud-terraform-tfstate`. Keys are:

```text
terraform-state/<environment>/us-east-1/proxy/terraform.tfstate
terraform-state/<environment>/us-east-1/v2v/terraform.tfstate
```

`state_bucket` must match the bucket passed to `terraform init`.
Pipelines supply it automatically. Remote-state reads require access to
the corresponding state objects; native locking requires access to the
`.tflock` objects. The pipelines use `AWS_DEV_OIDC_ROLE_ARN` for both
environments, matching the existing shared OIDC role configuration.

The deployment role and account policies must permit the existing proxy
network resources (including VPC, NAT and EIP creation), CloudFront VPC
origins, ECR push, ECS updates, and passing the task roles. Also permit asset
uploads and CloudFront invalidations. Previously documented SCP restrictions
on network creation must be resolved in AWS before provisioning the proxy.
No account permissions are changed by this repository update.

## Configuration

- `translation_enabled=false`: plain softphone, no browser translation policy.
- `translation_enabled=true`, `proxy_enabled=false`: direct AWS calls;
  only authenticated browser identities receive translation permissions.
- Both true: all translation goes through the authenticated proxy;
  browser identities have no translation permissions.

The checked-in environments enable proxy translation. All service regions
are validated as `us-east-1`. Nova uses `proxy_bedrock_model_id`;
Transcribe, Translate and Polly use their configured regions.
Apply the proxy target too when disabling translation or switching to direct
mode so the previously deployed proxy resources are removed.

SSO stays disabled in both environments by default. To enable it, create the
identity provider in the relevant Cognito pool first, then set `sso_enabled`
and its exact `sso_provider_name`. Token lifetimes are 12 hours for refresh
tokens and 20 minutes for access/ID tokens. Optional `proxy_allowed_groups`
restricts proxy access to those Cognito groups.

CSP starts report-only. Test Connect calling and translation before setting
`csp_enforced=true`. Add the CloudFront application origin to the Connect
instance's approved origins and ensure the agent has a Connect account.

The optional runtime SSM parameter
`<ssm_hierarchy>forceBackupTranslation` can be created separately. The
proxy has read-only access; a missing parameter means the switch is off.
Terraform owns deploy-time settings, so editing SSM alone does not change
the deployed frontend or IAM policies.

## Frontend assets

Terraform owns `frontend-config.js`; the pipeline owns the built assets.
Existing Terraform-managed asset objects are forgotten without deletion
through a `removed` block. Uploads exclude `frontend-config.js`, keep older
hashed chunks for open calls, and upload `index.html` last. Asset cleanup is
a separate maintenance operation after active sessions have ended.

For a local frontend deployment, build `webapp`, apply the V2V state, then
run this command from the environment directory:

```bash
bash ../../scripts/deploy-webapp.sh ../../webapp/dist
```

For a local proxy update, use the proxy backend key and explicitly pass
`enabled_modules=["proxy"]`, `proxy_runtime_enabled=true`, and the
immutable `proxy_container_image`. A later local infrastructure apply must
retain these settings, or source `scripts/preserve-proxy-runtime.sh` after
initializing the proxy state.

## Verification

Run `npm ci && npm test` in `proxy_backend` and
`npm ci && npm run build` in `webapp`.
Run `terraform init -backend=false` and `terraform validate` in both
environment directories.
Run `terraform test` in `modules/cloudfront_v2v`, `modules/ecs_proxy`,
and `modules/s3_v2v` to verify proxy routing, the container startup
contract, and the generated browser configuration.

After deployment, verify sign-in, Connect CCP initialization, an authenticated
`/ws` connection, `/api/fallback`, and a live translated Connect call.
CloudFront and ECS deployment success alone does not verify a live call.
