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
and module order. The Dev `data_table` choice shares the `connect` state because
those tables are also managed by the full Connect deployment.

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

## SNOW Lambda in Dev

The `lambda-snow-btsgsd-dev` target creates `SNOW_btsgsd-dev` in `us-east-1`.
Its source is `modules/lambda-snow-btsgsd-dev/src/lambda_function.py`, packaged
from `./src` with handler `lambda_function.lambda_handler`. It uses Python 3.14,
x86_64, 512 MB memory, an 8-second timeout, 512 MB ephemeral storage, a ZIP
package, configurable reserved concurrency (module default 300; Dev reserves
none unless `snow_lambda_reserved_concurrency` is set), automatic runtime
updates, and SnapStart on published versions. CloudWatch logs go to `/aws/lambda/SNOW_btsgsd-dev`.
Terraform manages a CloudFormation Lambda stack to support Python 3.14 with the
repository's existing AWS provider version.

Authenticated AWS CLI and Python are required for the read-only capacity check.
The CLI must use the same account as Terraform; the check is skipped when no
reservation is requested. Planning fails when the requested reservation would
leave fewer than 100 unreserved executions. A new 300 reservation requires at
least 400 currently unreserved executions; increase the regional
quota or release other reservations if needed. The check includes this function's
existing reservation when updating it. Capacity can still change between plan
and apply. Deployment permissions include `lambda:GetAccountSettings` and
`lambda:GetFunctionConcurrency`, plus IAM, S3, CloudWatch Logs, CloudFormation,
and Lambda management permissions.

Use the dedicated Dev backend so this Lambda does not share the existing Connect
or Lambda states. From the repository root:

```powershell
terraform -chdir=environments/dev init -reconfigure -backend-config=lambda-snow-btsgsd-dev.backend.hcl
terraform -chdir=environments/dev plan -var='enabled_modules=["lambda-snow-btsgsd-dev"]' -var='snow_lambda_python_executable=python' -out=snow-dev.tfplan
terraform -chdir=environments/dev apply snow-dev.tfplan
```

Use `python3` instead of `python` where appropriate. Optional
`snow_lambda_environment_variables` can supply `SN_INSTANCE` and `SN_SECRET_NAME`;
without them the supplied handler returns `Not Set`. This handler only prints
configuration and returns a response; it does not call ServiceNow or read a
Secrets Manager secret. Invoke the `VersionArn` from the `snow_lambda_dev` output
to use SnapStart. The new name uses a separate stack and does not resolve or
remove the old failed `SNOW-btsgsd-lambda` stack. Generate a fresh plan before
deploying. No new pipeline choice is added by this change.

## Azure Pipeline Flow

The pipeline in `azure-pipelines.yml` supports these parameters:

- `targetEnvironment`: `dev` or `dev-nsso`
- `targetModule`: `connect`, `data_table`, `lambda`, `proxy`, `v2v`,
  `s3_connect_reporting`, `lambda-ctr-survey`, `lambda-connect-daily-ctr-export`,
  `lambda-ctr-raw`, `iam-ctr`, or `lambda-snow-btsgsd-dev`
- `terraformAction`: `plan` or `apply`

The deployment region is fixed to `us-east-1` for both environments.

To deploy the five tables in `environments/dev/data_table.tf`, select
`targetEnvironment=dev`, `targetModule=data_table`, and `terraformAction=apply`
from `main`. Select `plan` first to review the proposed changes. This choice
uses `terraform-state/dev/us-east-1/connect/terraform.tfstate` and targets the
five CloudFormation table stacks plus their required Connect instance dependency.
The table names are `CustomerNumberDataTable`, `BTS_GSD-HR_Transfer`,
`BTSGSD-Survey-DataTable`, `BTS_GSD-Veeva_Transfer`, and `TopLevelBlockerMessage`.
It uses the existing OIDC credentials, approval environment, and saved-plan
apply stage. It is not available for `dev-nsso`. Use the `connect` choice when
deploying contact-flow changes, including updated table lookups.

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

Dev enables `dev_support_ai_agent_enabled=true` to create the new
`btsgsd-SupportAgent` and `btsgsd-SupportAgent-prompt`, both of type
`ORCHESTRATION`, in the existing Connect instance and assistant. Its stack is
`btsgsd-SupportAgent-dev`. The complete supplied prompt is stored at
`environments/dev/metadata/prompts/btsgsd-SupportAgent-prompt.yaml`; its original
system instructions and conversation messages are preserved, with only name,
type and description metadata added outside the system block. The runtime system
includes the module's tool-list placeholder and remains below 100000 characters.

The system source agent is `SelfServiceOrchestratorVoice`; its source prompt must
be `SelfServiceOrchestrationVoice` (a `system:` prefix is also accepted). Discovery
rejects a different source prompt rather than deploying with the wrong voice
template. The source tools, locale and guardrail are copied; the new custom prompt
replaces the source system instructions. Set
`-var='dev_support_ai_python_executable=python'` for local Windows source discovery.

SupportAgent requires `dev_ai_admin_security_profile_enabled=true`. Admin
assignment runs after the new agent and its published version are created, and
the `btsgsd_support_agent` output exposes its identifiers after that assignment.
The existing survey agent retains its own names and prompt; the legacy agent
remains disabled. Use the existing Dev `connect` backend and pipeline to deploy.

Dev sets `dev_ai_admin_security_profile_enabled=true`. The Terraform resource
`terraform_data.dev_ai_admin_security_profiles` looks up the existing `Admin`
profile and runs `modules/connect_ai_agent/assign_admin_security_profile.py`
during apply. It assigns Admin to all customer-created AI agents in the Dev
assistant, including their `$LATEST` and published versions. It verifies Admin
access for every version before removing previous profiles, then verifies that
each version uses only Admin. AWS system agents are retained as source templates;
agents explicitly configured for a different instance are skipped. Agent IDs and
voice-flow ARNs are retained. The pipeline does not need any changes.

The operation runs after managed AI-agent creation/updates and reruns when their
published outputs or the helper change. It does not detect external assignment
changes on every plan. To rerun explicitly, use
`-replace='terraform_data.dev_ai_admin_security_profiles[0]'` in a new plan.
Set `dev_ai_admin_security_profile_enabled=false` to stop managing assignments;
this does not undo assignments already applied. For local Windows runs, set
`-var='dev_ai_security_profile_python_executable=python'`.

For recovery from the reported `409 ResourceInUseException`, first apply the
Admin migration separately so obsolete profiles are detached before a full
apply can attempt to delete them. From `environments/dev`, initialized against
the same Dev `connect` backend used by the pipeline:

```bash
terraform plan -var='enabled_modules=["connect"]' \
  -target='terraform_data.dev_ai_admin_security_profiles[0]' \
  -out=ai-admin-migration.tfplan
terraform apply ai-admin-migration.tfplan
```

Then generate a fresh full Connect plan and apply it using the existing pipeline.
This migration also updates custom agents created outside Terraform in the same
assistant. Admin grants broad Connect permissions; tool configuration and
applicable human-agent permissions still govern which tools can be invoked.
The runner needs `wisdom:GetAssistant`, `wisdom:ListAIAgents`,
`wisdom:ListAIAgentVersions`, `connect:ListIntegrationAssociations`,
`connect:ListSecurityProfiles`, `connect:DescribeSecurityProfile`,
`connect:ListEntitySecurityProfiles`, `connect:AssociateSecurityProfiles`, and
`connect:DisassociateSecurityProfiles`, using the same AWS credentials as Terraform.
The existing Admin profile is reused and is not created or deleted by this code.
See the AWS APIs for [assigning profiles](https://docs.aws.amazon.com/cli/latest/reference/connect/associate-security-profiles.html)
and [detaching previous profiles](https://docs.aws.amazon.com/cli/latest/reference/connect/disassociate-security-profiles.html).

Dev also enables the separate `modules/connect_ai_agent` survey voice module via
`dev_survey_ai_agent_enabled=true`. It creates `btsgsd-ai-survey-agent` and
`btsgsd-ai-survey-prompt`, using `global.anthropic.claude-sonnet-5` only when
Connect lists it as an ACTIVE global orchestration model. The existing Connect
instance, Terraform-managed domain, and private template bucket are reused;
`dev_ai_agent_enabled=false` keeps the legacy custom agent disabled.

The survey instructions live in
`environments/dev/metadata/prompts/btsgsd-ai-survey-prompt.yaml`. Only the `prompt`
field is appended to the system voice template. The module's read-only
`read_source.py` helper copies `SelfServiceOrchestratorVoice` tools, locale,
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
`-var='dev_survey_ai_python_executable=python'`. Run `terraform init` after adding
the module to install the external provider. Keep using the Dev `connect` target
and its existing backend state.

`btsgsd_ai_survey_agent` returns the published identifiers and `AgentVersionArn`.
Publishing does not activate live calls: configure the voice bot/contact flow
to select the versioned agent ARN, verify knowledge-base access, and handle
return-to-control escalation. Disabling the survey flag
plans removal of the survey stack and its template object, retaining the
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
