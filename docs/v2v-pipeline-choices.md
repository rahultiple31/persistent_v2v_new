# V2V pipeline choices

Run `v2v-azure-pipeline.yml` from `main`. Select `targetEnvironment=v2v` for
the existing V2V choices below. Select the resource's module in
`targetModule` and use `terraformAction=plan` to review the changes. Select
the same module with `terraformAction=apply` to run a new Plan stage followed
by Apply of that run's saved plan. The earlier plan-only artifact is not reused.

The retired survey resources have two destruction-only `targetModule` choices
under `targetEnvironment=v2v`:

| Choice | Resources | Existing state |
| --- | --- | --- |
| `destroy_survey_ai` | `BTSGSD-V2V-US-AI-Survey-Agent`, `BTSGSD-V2V-US-AI-Survey-Prompt`, and their module-owned versions/helpers | `terraform-state/v2v/us-east-1/connect/terraform.tfstate` |
| `destroy_survey_lex` | `BTSGSD-V2V-US-AIAgent-Survey` and its module-owned locales/IAM resources | `terraform-state/v2v/us-east-1/lex_bot/terraform.tfstate` |

Run each choice with `terraformAction=plan` to review its destruction plan.
Use the same choice with `terraformAction=apply` to create and apply a new
destruction plan. Both choices use `-destroy` with explicit module targets.
Plan and Apply reject any managed changes except deletions inside those exact
retired module instances. An empty plan means no matching resources remain in
the selected state; verify state ownership if the resources still exist in AWS.
The retired module definitions stay removed, and `btsgsd_ai_survey_agent` is a
separate resource that these choices do not delete. Update the survey contact
flow routing before using it after the referenced AI agent or bot is deleted.

Select `targetEnvironment=v2v-resources` to deploy
`environments/v2v-resources`, whose module sources are in `v2v-resource-modules`.
Its `targetModule` choices are `cloudwatch`, `ssm`, `ecr`, `iam`, `networking`,
`alb`, `waf`, `ecs`, and `dns`. Select `all` for the complete root configuration.
Individual choices target `module.<name>` and include its Terraform dependencies.
Use `terraformAction=plan` first, then select `apply` after reviewing the changes.

All `v2v-resources` choices retain the existing shared backend key
`terraform-state/V2V-poc/terraform.tfstate` and explicitly load
`terraform.dev.tfvars`. They do not use V2V's `enabled_modules` variable or Lambda
packaging. The environment is recorded with the saved plan and checked before
Apply. Choices belonging to the other environment are rejected.

Individual choices target a resource or `module.<name>[0]` in its existing owning
state. Terraform includes dependencies needed by that target, which can
include other resources. It does not plan unrelated modules just because
they share the same state. Existing feature flags still apply: a disabled
module can produce an empty plan.

The `connect`, `v2v`, and `code-signing` choices deploy complete groups.
`connect` still requires the VMX3 queue, beep-prompt, and timestamper Lambda
ARN variables. An individual Lambda choice does not require those unrelated
VMX3 inputs. `connect-resources` retains its separate backend key and requires
`connect_resources_dependencies` containing the existing V2V resource UUIDs.

Each of these flow names is an individual `targetModule` choice in the existing
Connect state:

```text
BTSGSD-V2V-US-AbbVie_Views
BTSGSD-V2V-US-stdgsd_Fieldforce_Flow
BTSGSD-V2V-US-AgentToAgentTransferFlow
BTSGSD-V2V-US-OutboundWhisperFlow
BTSGSD-V2V-US-Transfer-To-Agent-CustomerQueueFlow
BTSGSD-V2V-US-VoicemailFlow
BTSGSD-V2V-US-btsgsd_HR
BTSGSD-V2V-US-placeholder-inbound-flow
BTSGSD-V2V-US-transfer-to-agent-customer-queue-flow
BTSGSD-V2V-US-outbound-whisper-flow
BTSGSD-V2V-US-agent-to-agent-transfer-flow
BTSGSD-V2V-US-HR
```

`BTSGSD-V2V-US-AbbVie_Views` is an alias for `abbvie_views`. The other choices
target individual contact-flow resources inside `module.connect_us_east_1[0]`.
Terraform still includes dependencies. Imported flows share dependency
expressions with the customer-queue resolver, so selecting one does not
guarantee exclusion of existing VMX3 lookups. Review the plan before applying.
The existing `connect_us_east_1` choice continues to target the entire module.

Each of these data-table choices targets its own CloudFormation stack in the
existing Connect state. Select the table name in `targetModule`; the `connect`
choice is not required. Except for `BTSGSD-V2V-US-CustomerNumberDataTable`,
the table uses the existing instance resolved by
`connect_instance_alias`, without deploying the Connect module or requiring
VMX3 inputs. The Connect instance must already exist.

| Data table | Pipeline choice |
| --- | --- |
| BTSGSD-V2V-US-CustomerNumberDataTable | `BTSGSD-V2V-US-CustomerNumberDataTable` |
| BTSGSD-V2V-US-BTSGSD-CustomerNumber | `BTSGSD-V2V-US-BTSGSD-CustomerNumber` |
| BTSGSD-V2V-US-BTSGSD-HR_Transfer | `BTSGSD-V2V-US-BTSGSD-HR_Transfer` |
| BTSGSD-V2V-US-PROMPT-DATATABLE | `BTSGSD-V2V-US-PROMPT-DATATABLE` |
| BTSGSD-V2V-US-BTSGSD-Veeva_Transfer | `BTSGSD-V2V-US-BTSGSD-Veeva_Transfer` |
| BTSGSD-V2V-US-TopLevelBlockerMessage | `BTSGSD-V2V-US-TopLevelBlockerMessage` |

`BTSGSD-V2V-US-CustomerNumberDataTable` targets
`aws_cloudformation_stack.customer_number_data_table[0]` in the existing
Connect state. Its instance ARN comes from `module.connect_us_east_1[0]`,
so Terraform also includes that module's dependencies in the plan. Review
those changes before running the same choice with `terraformAction=apply`.

`connect_external_vms` targets `module.external_vms[0]` in the same
`connect-resources` state. It creates the `External VMs` phone quick connect
using `external_vm_phone_number`, currently `+18557117965`. The
`enable_external_vms` flag must be true. The module uses the selected Connect
instance alias and the `us-east-1` provider.

This quick connect is separate from the `External VMs` agent status managed
by `connect-resources`. Creating the quick connect does not resolve an
`AlreadyExists` error for that agent status; the existing status must be
identified and reconciled with its owning Terraform state.

| Lambda | Pipeline choice |
| --- | --- |
| BTSGSD-V2V-US-lambda-test | `lambda` or `lambda_us_east_1` |
| BTSGSD-V2V-US-CTR-Survey | `lambda-ctr-survey` |
| BTSGSD-V2V-US-connect-daily-ctr-export | `lambda-connect-daily-ctr-export` |
| BTSGSD-V2V-US-CTR-Raw | `lambda-ctr-raw` |
| BTSGSD-V2V-US-SNOW | `BTSGSD-V2V-US-SNOW` |
| BTSGSD-V2V-US-ServiceNow_Interaction | `BTSGSD-V2V-US-ServiceNow_Interaction` |
| BTSGSD-V2V-US-Nextthink_Handoff | `BTSGSD-V2V-US-Nextthink_Handoff` |
| BTSGSD-V2V-US-UpdateSessionAttributes | `BTSGSD-V2V-US-UpdateSessionAttributes` |
| BTSGSD-V2V-US-silence_guard | `silence_guard-dev` |
| BTSGSD-V2V-US-conversionOfQueueMetrics | `conversion_of_queue_metrics` |
| BTSGSD-V2V-US-lex-QueueFlow-Callback | `BTSGSD-V2V-US-lex-QueueFlow-Callback` or `lex_queueflow_callback` |
| BTSGSD-V2V-US-lex-yesNo | `BTSGSD-V2V-US-lex-yesNo` or `lex_yesno` |

The `BTSGSD-V2V-US-UpdateSessionAttributes` choice also manages the
`BTSGSD-V2V-US-UpdateSessionAttributes-warmup` EventBridge Scheduler schedule in the existing
Connect state. It runs every five minutes with flexible time window disabled,
targets that Lambda with `{"warmup":true}`, and retries delivery up to 185 times
within a maximum event age of 86400 seconds (one day).

The execution role `BTSGSD-IVA-Lambda-Warmup-Scheduler-Role` must already exist
and trust `scheduler.amazonaws.com`. The module adds an inline policy allowing
that role to invoke this Lambda. The deployment identity needs permission to
read the role, manage its inline policy and the schedule, and pass the role to
Scheduler.

If the schedule already exists in the `default` group outside Terraform, add
this import block to `environments/v2v/imports.tf` before running Plan/Apply.
Omit it when creating a new schedule. Do not import a schedule owned by another
Terraform state without first transferring its ownership.

```hcl
import {
  for_each = local.deploy_connect ? {
    existing = "default/BTSGSD-V2V-US-UpdateSessionAttributes-warmup"
  } : {}

  to = module.BTSGSD-V2V-US-UpdateSessionAttributes[0].aws_scheduler_schedule.warmup
  id = each.value
}
```

The `BTSGSD-V2V-US-SNOW` choice also manages `BTSGSD-V2V-US-SNOW-warmup` in the
existing `terraform-state/v2v/us-east-1/lambda-snow-btsgsd-dev/terraform.tfstate`
state. The enabled schedule runs hourly (`rate(1 hour)`) with flexible time
window disabled and targets `BTSGSD-V2V-US-SNOW` with `{"warmup":true}`.
It uses the same existing warm-up execution role, with a separate inline policy
limited to the SNOW function, a maximum event age of 86400 seconds, and 185
delivery retries. Its unqualified Lambda ARN targets `$LATEST`.

If this schedule already exists in the `default` group outside Terraform, add
the following import block before running the SNOW choice. Omit it for a new
schedule, and transfer state ownership first if another state manages it.

```hcl
import {
  for_each = contains(local.enabled_module_set, "btsgsd-v2v-us-snow") ? {
    existing = "default/BTSGSD-V2V-US-SNOW-warmup"
  } : {}

  to = module.BTSGSD-V2V-US-SNOW[0].aws_scheduler_schedule.warmup
  id = each.value
}
```

The `silence_guard-dev` choice also manages the enabled
`BTSGSD-V2V-US-silence_guard-warmup` schedule in the existing Connect state. It invokes
`BTSGSD-V2V-US-silence_guard` hourly with flexible time window disabled and
`{"warmup":true}`, so the wrapper bypasses guard business logic. It reuses
`BTSGSD-IVA-Lambda-Warmup-Scheduler-Role` with its own inline invoke policy,
a maximum event age of 86400 seconds, and 185 delivery retries.

If this schedule already exists in the `default` group outside Terraform, add
the following import block before running `silence_guard-dev`. Omit it for a
new schedule, and transfer ownership first if another Terraform state owns it.

```hcl
import {
  for_each = local.deploy_connect ? {
    existing = "default/BTSGSD-V2V-US-silence_guard-warmup"
  } : {}

  to = module.silence_guard-dev[0].aws_scheduler_schedule.warmup
  id = each.value
}
```

The `BTSGSD-V2V-US-ServiceNow_Interaction` choice also manages the enabled
`BTSGSD-V2V-US-ServiceNow_Interaction-warmup` schedule in its existing
`terraform-state/v2v/us-east-1/lambda-servicenow-interaction/terraform.tfstate`
state. It runs hourly with flexible time window disabled, targeting
`BTSGSD-V2V-US-ServiceNow_Interaction` with `{"warmup":true}`. It reuses
`BTSGSD-IVA-Lambda-Warmup-Scheduler-Role` with an inline policy scoped to this
function, a maximum event age of 86400 seconds, and 185 delivery retries.

If this schedule already exists in the `default` group outside Terraform, add
the following import block before running the ServiceNow Interaction choice.
Omit it for a new schedule, and transfer ownership first if another state owns it.

```hcl
import {
  for_each = contains(local.enabled_module_set, "btsgsd-v2v-us-servicenow_interaction") ? {
    existing = "default/BTSGSD-V2V-US-ServiceNow_Interaction-warmup"
  } : {}

  to = module.BTSGSD-V2V-US-ServiceNow_Interaction[0].aws_scheduler_schedule.warmup
  id = each.value
}
```

The `BTSGSD-V2V-US-Nextthink_Handoff` choice also manages the enabled
`BTSGSD-V2V-US-Nextthink_Handoff-warmup` schedule in its existing
`terraform-state/v2v/us-east-1/lambda-nextthink-handoff/terraform.tfstate` state.
It runs hourly with flexible time window disabled and invokes that Lambda
with `{"warmup":true}`. It reuses `BTSGSD-IVA-Lambda-Warmup-Scheduler-Role`
with its own narrowly scoped invoke policy, a maximum event age of 86400
seconds, and 185 delivery retries. The function uses `warmup_wrapper.handler`
with `ORIGINAL_HANDLER=lambda_function.lambda_handler` so scheduled pings skip
the Nexthink authentication and handoff calls. The existing business handler
and required secret-name setting are preserved.

If this schedule already exists in the `default` group outside Terraform, add
the following import block before running the Nextthink Handoff choice. Omit
it for a new schedule, and transfer ownership first if another state owns it.

```hcl
import {
  for_each = contains(local.enabled_module_set, "btsgsd-v2v-us-nextthink_handoff") ? {
    existing = "default/BTSGSD-V2V-US-Nextthink_Handoff-warmup"
  } : {}

  to = module.BTSGSD-V2V-US-Nextthink_Handoff[0].aws_scheduler_schedule.warmup
  id = each.value
}
```

`lex_bot`, `lex_yesno_bot`, and `lex_customer_queue_flow_bot`
now target their respective bots. `cloudwatch_log_group`
and `lex_yesno_log_group` select their respective log groups. The
`support_agent_tools` choice was removed because that helper module creates
no AWS resources; its output is used by `btsgsd_support_agent`.

Use `btsgsd_support_agent_tools_access` to grant the existing Connect `Admin`
security profile access to the three configured MCP tools. This separate choice
reads the existing gateway and support-agent CloudFormation stacks and assigns
Admin to the agent's unversioned ARN and current numeric published-version ARN.
It strips an existing `:$LATEST` suffix and builds the published ARN from the
stack's `AgentVersion` output. Existing Admin associations and complete MCP
tool permissions are skipped. It does not deploy
the gateway, AI agent or prompt. Those stacks and the registered Connect MCP
integration must already exist. Existing application/tool grants and other
attached security profiles are retained. The original `btsgsd_support_agent`
choice deploys the agent and prompt without running this grant.
The access choice uses the existing Connect state. If the earlier in-module
grant was applied, its marker may remain until a complete group plan removes
it. That hook has no destroy provisioner, so removing its marker does not
revoke existing AWS grants. The new choice manages its own grant marker.
The deployment identity needs `connect:ListSecurityProfiles`,
`connect:ListSecurityProfileApplications`, `connect:UpdateSecurityProfile`,
`connect:ListEntitySecurityProfiles`, `connect:AssociateSecurityProfiles`, and
`cloudformation:DescribeStacks` for the two existing stacks.

The IT Support `lex_bot` choice looks up the Q in Connect built-in intent
signature for each configured locale before changing any intents. The pipeline's
AWS deployment role needs `lex:ListBuiltInIntents`; this is separate from the
bot's execution role. If a locale does not return the intent, Apply stops with
the locale name so its availability can be resolved before retrying. The script
uses the exact signature returned by AWS and follows all response pages.

Plan builds the file-based Connect Lambda ZIPs and saves every deployment
ZIP under `metadata` in the plan artifact, including packages produced by
Terraform's archive provider. Apply restores the exact ZIP bytes before
validating and applying the saved plan. The plan context includes the commit,
region, backend key, and selected choice.

State paths and Terraform module addresses are preserved. No state migration
is needed for this selector change. Prerequisites owned by other states must
already exist, including IAM roles, the Lambda code-signing configuration,
and configured Connect dependencies. The existing AWS OIDC pipeline variable
is still required.

Scoped choices use Terraform resource targeting. HashiCorp recommends
separate configurations for routine independent lifecycles; targeting can
leave outputs or other pending changes incomplete. Review each plan and run
a complete group plan when its required inputs are available to check for
remaining changes. See the
[Terraform targeting documentation](https://developer.hashicorp.com/terraform/cli/commands/plan#resource-targeting).
