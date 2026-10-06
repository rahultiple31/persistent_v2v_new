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
