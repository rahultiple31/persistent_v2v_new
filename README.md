# Azure DevOps CI/CD to AWS Amazon Connect Environments

This repository contains Terraform for Amazon Connect in AWS Dev and Dev NSSO
environments. Azure Repos and Azure Pipelines deploy both environments in
`us-east-1`.

## Environments

- Dev: `environments/dev`
- Dev NSSO: `environments/dev-nsso`

Each environment has its own Terraform root, variable values, backend state key,
and Azure DevOps approval environment. Both environments use the shared Connect
module in `modules/connect`.

The pipeline also selects one infrastructure module per run. Each selected
module uses its own Terraform state file in S3 using the environment, region,
and module order.

## Region

All application infrastructure is deployed in `us-east-1`.

## Architecture

Each environment can deploy Amazon Connect, Lambda smoke-test, and V2V
application infrastructure modules. The shared Connect module creates:

- Amazon Connect instance
- Primary queue
- Agent security profile
- Primary routing profile
- Placeholder inbound contact flow

No VPC, subnet, NAT, route table, Lex, DynamoDB, CloudTrail, API Gateway,
Secrets Manager, or Contact Lens modules are part of the Connect target.

The disposable Lambda test module can be selected separately for pipeline smoke
testing. It creates:

- One Python Lambda function for simple pipeline testing
- One IAM execution role for the Lambda function
- AWS managed Lambda basic execution policy attachment

The V2V target deploys the Nova frontend and authentication stack. It creates:

- Amazon Cognito user pool, app client, domain, and identity pool
- IAM roles and policies for Cognito identities
- S3 buckets and objects for V2V application hosting and CloudFront logs
- CloudFront distribution and security headers, with optional proxy VPC origin and WebSocket/API routing
- SSM Parameter Store configuration values

Both environments default to `proxy_integration_enabled=false`, so V2V can
deploy without proxy state or ALB values. With proxy translation selected,
translation stays disabled until integration is explicitly enabled.

The separate proxy target deploys the private ALB, ECS Fargate runtime, and
supporting network. See [DEPLOY-V2V.md](DEPLOY-V2V.md) for the staged deployment
of both environments, runtime activation, and verification.

## Backend

Terraform uses an S3 backend with native S3 state locking:

```hcl
terraform {
  backend "s3" {
    use_lockfile = true
  }
}
```

Create the backend bucket before running the pipeline. The Azure pipeline uses:

```text
bucket: bts-cloud-terraform-tfstate
dev key: terraform-state/dev/us-east-1/connect/terraform.tfstate
dev-nsso key: terraform-state/dev-nsso/us-east-1/connect/terraform.tfstate
region: us-east-1
encrypt: true
use_lockfile: true
```

The backend key pattern is:

```text
terraform-state/<environment>/<region>/<module>/terraform.tfstate
```

The same environment/region/module order is used for pipeline plan artifacts and
display names.

Examples:

```text
terraform-state/dev/us-east-1/connect/terraform.tfstate
terraform-state/dev-nsso/us-east-1/connect/terraform.tfstate
terraform-state/dev/us-east-1/lambda/terraform.tfstate
terraform-state/dev/us-east-1/v2v/terraform.tfstate
```

## Local Terraform

From either environment root:

```bash
cd environments/dev
# or
cd environments/dev-nsso

terraform init -reconfigure \
  -backend-config="bucket=bts-cloud-terraform-tfstate" \
  -backend-config="key=terraform-state/dev/us-east-1/connect/terraform.tfstate" \
  -backend-config="region=us-east-1" \
  -backend-config="encrypt=true"

terraform fmt -recursive ../..
terraform validate
terraform plan
```

Use the matching backend key for the selected environment. For Dev NSSO, use:

```text
terraform-state/dev-nsso/us-east-1/connect/terraform.tfstate
```

To activate only the Connect module in this state:

```bash
terraform plan -var='enabled_modules=["connect"]'
```

To activate only the Lambda test module in this state:

```bash
terraform plan -var='enabled_modules=["lambda"]'
```

To activate only the V2V application stack in this state:

```bash
terraform plan -var='enabled_modules=["v2v"]'
```

## Azure Pipeline Flow

The pipeline in `azure-pipelines.yml` supports these parameters:

- `targetEnvironment`: `dev` or `dev-nsso`
- `targetModule`: `connect`, `lambda`, `proxy`, or `v2v`
- `terraformAction`: `plan` or `apply`
- `deployAiAgent`: enable the Dev AI agent with the `dev` / `connect` target

The deployment region is fixed to `us-east-1` for both environments.

The proxy target requires EC2 network bootstrap permissions, including
`ec2:CreateVpc` and `ec2:AllocateAddress`. Previously documented AWS Organizations
SCP restrictions must be resolved before deploying it.

When more modules are added later, add the module name to:

- `targetModule` values in `azure-pipelines.yml`
- `enabled_modules` validation in each environment's `variables.tf`
- module gating locals and module blocks in each environment root
- the pipeline target mapping for region and module

The flow is:

```text
Code Commit -> Terraform Init -> Plan -> Approval -> Apply
```

The apply stage is gated through the Azure DevOps environment selected by
`targetEnvironment`. Configure the `dev` and `dev-nsso` Azure DevOps environments
with the review and approval checks your team needs.

Required Azure DevOps variables:

- `AWS_DEV_OIDC_ROLE_ARN`: shared AWS IAM role ARN assumed for Dev and Dev NSSO

The pipeline uses Azure Pipelines OIDC and Terraform's AWS web identity
authentication. It does not require static AWS access keys.

### Dev Connect AI Agent

Configure these Azure pipeline variables before selecting `deployAiAgent=true`:

- `AWS_DEV_AI_ASSISTANT_ID`: existing assistant UUID associated with `btsgsd-dev-us-east-1`.
- `AWS_DEV_AI_PROMPT_MODEL_ID`: Connect-supported orchestration model ID in `us-east-1`.
- `AWS_DEV_AI_TEMPLATE_BUCKET`: existing private S3 template bucket in `us-east-1`.
- `AWS_DEV_AI_TOOLS_JSON`: complete CloudFormation-format JSON array for the
  `Retrieve` and `GenerateNotes` tools, including their actual tool IDs and any
  applicable schemas, overrides, and instructions. Use a secret pipeline variable
  if the configuration contains sensitive data. Tool names alone are insufficient.

Run from `main` with `targetEnvironment=dev`, `targetModule=connect`,
`deployAiAgent=true`, and `terraformAction=plan`. Review the plan for
`aws_s3_object.dev_ai_template[0]` and `aws_cloudformation_stack.dev_ai_agent[0]`,
then run with `terraformAction=apply` and approve the Dev deployment.

The pipeline passes the Azure AI inputs directly to `terraform plan` using
explicit `-var` arguments; no Python helper or generated variable file is needed.
These arguments override the disabled local defaults in
`environments/dev/terraform.tfvars`; setting `TF_VAR_*` alone would not override
those defaults. See [Terraform variable precedence](https://developer.hashicorp.com/terraform/language/values/variables#variable-definition-precedence).
The apply stage uses the saved plan, so it does not rebuild the AI configuration.

Subsequent Dev Connect runs detect AI resources in state and require the same
pipeline inputs even if the checkbox is not selected. Missing inputs fail the
run instead of planning deletion of an existing or partially deployed agent.
Dev NSSO and the other module targets remain unchanged.

The OIDC deployment role needs CloudFormation stack management, the applicable
`wisdom` AI prompt/agent/version permissions, and S3 template upload/read/delete
permissions in addition to its existing Connect and state backend access. The
template bucket must be readable by the deployment identity; keep public access
blocked. The AI assistant, knowledge access, and tools must already be configured
for the target Dev instance. Do not reuse an assistant ID from another instance.

This deploys the custom orchestration prompt and publishes an agent version. It
does not change assistant defaults or contact flows to activate the new version.
Associate the published agent version with the intended Dev use case/flow before
testing live interactions. Restrict access to plan artifacts and Terraform state,
which contain deployment inputs even when Azure variables are marked secret.

Optional Amazon Connect administrator variables for the plan stage:

- `connectAdminUserEnabled`: set to `true` to create the administrator user
- `connectAdminFirstName`: administrator first name
- `connectAdminLastName`: administrator last name
- `connectAdminUsername`: administrator username
- `connectAdminEmail`: administrator email address

Terraform only needs one password value. The `Password (verify)` field exists
in the AWS Console form, but it is not a Terraform argument.

The AWS IAM roles must trust the Azure DevOps OIDC issuer for this pipeline.
The pipeline requests the OIDC token from `System.OidcRequestUri`, writes it to a
temporary token file, and exports:

```text
AWS_ROLE_ARN
AWS_WEB_IDENTITY_TOKEN_FILE
AWS_ROLE_SESSION_NAME
```

Make sure the pipeline can access `System.AccessToken`, because it is used to
request the OIDC token from Azure DevOps.
