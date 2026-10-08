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

### Dev Connect AI Agent

Dev also enables the separate `modules/connect_ai_agent` support voice module via
`dev_support_ai_agent_enabled=true`. It creates `btsgsd-support-agent` and
`btsgsd-support_prompts`, using `global.anthropic.claude-sonnet-5` only when
Connect lists it as an ACTIVE global orchestration model. The existing Connect
instance, Terraform-managed domain, and private template bucket are reused;
`dev_ai_agent_enabled=false` keeps the legacy custom agent disabled.

The support instructions and test case live in
`environments/dev/metadata/prompts/btsgsd-support_prompts.yaml`. Only the `prompt`
field is appended to the system voice template. The module's read-only
`read_source.py` helper copies `SelfServiceOrchestrationVoice` tools, locale,
guardrail, and prompt context, and removes the assistant prefill for Sonnet 5.
Populated source fields not supported by CloudFormation stop discovery instead
of being silently discarded. Discovery runs during planning when its inputs are
known, or during apply when the domain or other dependencies are changing.

The runner needs Python 3, AWS CLI v2 with the current QConnect commands, and the
same AWS credentials as Terraform. Azure's existing OIDC credentials are
inherited; the helper needs `wisdom:GetAssistant`, `wisdom:ListModels`,
`wisdom:ListAIAgents`, `wisdom:GetAIAgent`, `wisdom:GetAIPrompt`, and
`connect:ListIntegrationAssociations`, in addition to the existing deployment
permissions. For local Windows runs, set
`-var='dev_support_ai_python_executable=python'`. Run `terraform init` after adding
the module to install the external provider. Keep using the Dev `connect` target
and its existing backend state.

`btsgsd_support_agent` returns the published identifiers and `AgentVersionArn`.
Publishing does not activate live calls: configure the voice bot/contact flow
to select the versioned agent ARN, verify knowledge-base access, and handle
return-to-control escalation. `btsgsd_support_agent_test` returns the YAML test
case without sending that metadata to the model. Disabling the support flag
plans removal of the support stack and its template object, retaining the
separately managed domain and bucket.

The original pipeline deploys the AI domain and optional custom agent as part of
the Dev `connect` target.
No AI pipeline parameter, AI-specific Azure variables, or preparation script is
required. The `btsgsd-dev-us-east-1` instance is configured with
`dev_ai_domain_enabled=true` and `dev_ai_agent_enabled=false` in
`environments/dev/terraform.tfvars`. The legacy custom agent is disabled and its model
ID is unset. From `main`, run `targetEnvironment=dev`, `targetModule=connect`,
and `terraformAction=plan`. Review deletion of the managed custom-agent stack,
its template object, and model-validation resource, then run a fresh pipeline
with `terraformAction=apply` and approve the Dev deployment. The stack deletion
removes its custom prompt, agent, and versions. The Connect instance, domain,
and private template bucket (including public-access blocking and encryption)
remain managed. No model check runs during removal. Do not use a full destroy.
If the failed stack is absent from Terraform state, it will not appear in the
deletion plan; delete only `btsgsd-dev-us-east-1-ai-agent` in CloudFormation.

To re-enable a custom agent later, set `dev_ai_agent_enabled=true` and supply
a currently supported orchestration model. The previously configured Claude 3.7
model was rejected as no longer supported. Confirm an ACTIVE model for this
assistant before enabling deployment. Run in AWS CloudShell using the same Dev
AWS account:

```bash
ASSISTANT_ID=$(aws cloudformation describe-stacks \
  --stack-name btsgsd-dev-us-east-1-ai-domain \
  --region us-east-1 \
  --query "Stacks[0].Outputs[?OutputKey=='AssistantId'].OutputValue | [0]" \
  --output text)

aws qconnect list-models \
  --assistant-id "$ASSISTANT_ID" \
  --ai-prompt-type ORCHESTRATION \
  --model-lifecycle ACTIVE \
  --region us-east-1 \
  --query 'modelSummaries[].{ModelId:modelId,Lifecycle:modelLifecycle}' \
  --output table
```

If the configured ID is absent, use an exact returned model ID instead, preferring
an ACTIVE model compatible with the prompt. Do not assume Bedrock availability
implies QConnect availability. Model discovery requires `wisdom:ListModels`.
Terraform also performs this read-only model check at apply time, after the Dev
assistant is available and before creating the custom-agent stack. It runs when
the assistant/model changes; it is not a continuous availability monitor. A
missing or unavailable model stops deployment and prints available orchestration
IDs instead of attempting `DevPrompt` creation. Authentication/API errors also
stop the check; Terraform never silently selects a fallback model. The runner
needs Bash, AWS CLI v2 with `qconnect list-models`, and the same AWS account/session
as the provider. The existing Azure OIDC environment is inherited; no pipeline
update or preparation script is added. For manual runs using provider-specific
profiles/assume-role settings, configure the CLI to use the same identity first.
No mock tool IDs or fabricated knowledge are configured. Retrieval, note
generation and external actions are unavailable with `dev_ai_tools=[]`.

Run from `main` with `targetEnvironment=dev`, `targetModule=connect`, and
`terraformAction=plan`. Review the plan for
`aws_cloudformation_stack.dev_ai_domain[0]`, the private S3 template bucket/object,
`terraform_data.dev_ai_model_validation[0]`, and
`aws_cloudformation_stack.dev_ai_agent[0]`, then run with
`terraformAction=apply` and approve the Dev deployment. This stack creates the
`btsgsd-dev-us-east-1-ai-domain` assistant in `us-east-1` and associates it with the
instance returned by `module.connect_us_east_1`. The domain uses default AWS-owned
encryption. For domain-only bootstrap, set `dev_ai_agent_enabled=false`; the
domain itself does not require a template bucket, prompt, model, or tool inputs.
The `dev_ai_domain` output returns its name, assistant UUID/ARN and instance ARN.
Use the existing Connect backend state; an existing instance must already be
managed there, otherwise Terraform will attempt to create it.
The domain stack uses [AWS::Wisdom::Assistant](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-wisdom-assistant.html)
and [AWS::Connect::IntegrationAssociation](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-connect-integrationassociation.html).
The instance must not already have a domain associated with it.

For a retry after `DevPrompt` failed, generate a fresh plan using the same Dev
Connect backend. Review whether Terraform proposes replacing the failed
`btsgsd-dev-us-east-1-ai-agent` stack. A stack in `ROLLBACK_COMPLETE` cannot be
updated. If the plan proposes an update rather than replacement, delete only
that failed stack in the CloudFormation console, wait for deletion, and rerun
the pipeline so Terraform refreshes state and generates a new plan. Keep the
domain stack, Connect instance and template bucket. Do not manually remove state
entries or reuse the failed run's saved plan. See
[AWS stack statuses](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/view-stack-events.html).

For tool-enabled testing, enable the custom agent, keep `dev_ai_agent_test_mode=false`, and supply:

- `dev_ai_assistant_id`: leave null to use the Terraform-created domain. To reuse
  a different existing Dev assistant instead, disable `dev_ai_domain_enabled`
  and supply that assistant UUID. Do not switch off an already-managed domain
  without reviewing its planned deletion.
- `dev_ai_prompt_model_id`: Connect-supported orchestration model ID in `us-east-1`.
- `dev_ai_template_bucket`: `atsgsd-dev-us-east-1-ai-agent`; Terraform creates this
  private, AES256-encrypted template bucket in `us-east-1` with public access
  blocked. The name must be available. Import it first if it already exists and
  is owned by this account rather than attempting to create it again.
- `dev_ai_tools`: complete CloudFormation-format tool configurations for
  `Retrieve` and `GenerateNotes`, including actual tool IDs and applicable
  schemas, overrides, and instructions. Tool names alone are insufficient.

The bucket name is configured; the model ID must be supplied before re-enabling
the custom agent. The empty tool list is allowed only
for explicit prompt-only test mode; non-test deployment still validates the
required Retrieve and GenerateNotes configurations. Provided nonempty tool lists
must satisfy that validation even in test mode. AWS makes tool configuration
optional for [orchestration agents](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-properties-wisdom-aiagent-orchestrationaiagentconfiguration.html);
Terraform omits the property entirely for the tool-free smoke test.
Do not commit credentials or sensitive tool settings to the repository.

For the custom agent, review the plan for
`aws_s3_bucket.dev_ai_template[0]`, `aws_s3_object.dev_ai_template[0]`, and
`aws_cloudformation_stack.dev_ai_agent[0]`,
then run with `terraformAction=apply` and approve the Dev deployment.

Domain and custom-agent resources are enabled independently and only with the
Connect target. Other Dev module runs ignore the AI inputs, and Dev NSSO is
unchanged. Keep the domain flag enabled to retain its managed stack, and leave
the custom-agent flag disabled to prevent recreation. Disabling either flag
intentionally plans removal of the corresponding managed stack. The template
bucket and its security settings remain while its name is configured; setting
the bucket name to null with the agent disabled schedules their deletion.
The apply stage uses the saved plan.

The OIDC deployment role needs CloudFormation stack management, `wisdom`
assistant create/get/delete/tag permissions, and Connect integration association
create/list/delete permissions in addition to its existing Connect and state
backend access. Custom-agent deployment additionally needs the applicable
`wisdom` AI prompt/agent/version permissions, S3 bucket creation/configuration,
and template upload/read/delete permissions. The
template bucket must be readable by the deployment identity; keep public access
blocked. Domain creation does not create a knowledge base or configure retrieval
tools. Configure knowledge access and tools before tool-enabled testing.
Do not reuse an assistant ID from another instance.

Enabling the custom agent deploys its orchestration prompt and publishes an agent
version. It does not change assistant defaults or contact flows to activate the
new version.
Use only synthetic conversations in Agent Builder/testing. The supplied prompt
is for human-agent assistance, not autonomous customer self-service. Do not
assign this tool-free test agent to live default use cases/contact flows.
For full integration testing, first configure knowledge access and real tools,
disable test mode, and associate the published version with a test use case/flow.
Restrict access to plan artifacts and Terraform state,
which contain deployment inputs even when Terraform variables are sensitive.

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
