# V2V pipeline choices

Run `v2v-azure-pipeline.yml` from `main`. Select the resource's module in
`targetModule` and use `terraformAction=plan` to review the changes. Select
the same module with `terraformAction=apply` to run a new Plan stage followed
by Apply of that run's saved plan. The earlier plan-only artifact is not reused.

Individual choices target `module.<name>[0]` in the module's existing owning
state. Terraform includes dependencies needed by that module, which can
include other resources. It does not plan unrelated modules just because
they share the same state. Existing feature flags still apply: a disabled
module can produce an empty plan.

The `connect`, `v2v`, and `code-signing` choices deploy complete groups.
`connect` still requires the VMX3 queue, beep-prompt, and timestamper Lambda
ARN variables. An individual Lambda choice does not require those unrelated
VMX3 inputs. `connect-resources` retains its separate backend key and requires
`connect_resources_dependencies` containing the existing V2V resource UUIDs.

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

`lex_bot`, `lex_yesno_bot`, `lex_customer_queue_flow_bot`, and
`lex_aiagent_survey_bot` now target their respective bots. `cloudwatch_log_group`
and `lex_yesno_log_group` select their respective log groups. The
`support_agent_tools` choice was removed because that helper module creates
no AWS resources; its output is used by `btsgsd_support_agent`.

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
