#!/usr/bin/env bash
# Dedicated V2V selector; source this file from v2v-azure-pipeline.yml.
# Individual choices target their module and dependencies in the owning state.
# connect, v2v, and code-signing deploy their complete groups.
# This script is independent of scripts/terraform-target.sh.

DEPLOYMENT_TARGET="${1:?V2V target module is required}"
DEPLOYMENT_ENVIRONMENT="${2:-v2v}"
DEPLOYMENT_REGION="${3:-us-east-1}"

if [ "$DEPLOYMENT_ENVIRONMENT" != v2v ] ||
   [ "$DEPLOYMENT_REGION" != us-east-1 ]; then
  echo "This selector supports only v2v in us-east-1." >&2
  return 1
fi

TERRAFORM_STATE_MODULE=""
TERRAFORM_TARGET_ADDRESS=""

# choice | existing state group | optional module target
while IFS='|' read -r v2v_choice v2v_group v2v_address; do
  if [ "$v2v_choice" = "$DEPLOYMENT_TARGET" ]; then
    TERRAFORM_STATE_MODULE="$v2v_group"
    TERRAFORM_TARGET_ADDRESS="$v2v_address"
    break
  fi
done <<'V2V_CHOICES'
connect|connect|
lambda|lambda|module.lambda_us_east_1[0]
v2v|v2v|
dynamodb|dynamodb|module.queue_info_dynamodb[0]
btsgsd-intent-kb|btsgsd-intent-kb|module.s3_intent_kb[0]
code-signing|code-signing|
signing_profile|code-signing|module.signing_profile[0]
code_signing_config|code-signing|module.code_signing_config[0]
connect-resources|connect-resources|module.connect_resources[0]
connect_external_vms|connect-resources|module.external_vms[0]
connect_us_east_1|connect|module.connect_us_east_1[0]
btsgsd-Main-IB-Flow|connect|module.btsgsd-Main-IB-Flow[0]
connect_views|connect|module.connect_views[0]
abbvie_views|connect|module.abbvie_views[0]
connect_queue|connect|module.connect_queue[0]
btsgsd_support_agent|connect|module.btsgsd_support_agent[0]
btsgsd_support_agent_tools_access|connect|module.btsgsd_support_agent_tools_access[0]
btsgsd_ai_survey_agent|connect|module.btsgsd_ai_survey_agent[0]
survey_ai_prompt|connect|module.survey_ai_prompt[0]
connect_ai_agent|connect|module.connect_ai_agent[0]
agentcore_gateway|connect|module.agentcore_gateway[0]
connect_Integrations|connect|module.connect_Integrations[0]
lambda_us_east_1|lambda|module.lambda_us_east_1[0]
lambda-ctr-survey|lambda-ctr-survey|module.lambda-ctr-survey[0]
lambda-connect-daily-ctr-export|lambda-connect-daily-ctr-export|module.lambda-connect-daily-ctr-export[0]
lambda-ctr-raw|lambda-ctr-raw|module.lambda-ctr-raw[0]
BTSGSD-V2V-US-SNOW|btsgsd-v2v-us-snow|module.BTSGSD-V2V-US-SNOW[0]
BTSGSD-V2V-US-ServiceNow_Interaction|btsgsd-v2v-us-servicenow_interaction|module.BTSGSD-V2V-US-ServiceNow_Interaction[0]
BTSGSD-V2V-US-Nextthink_Handoff|btsgsd-v2v-us-nextthink_handoff|module.BTSGSD-V2V-US-Nextthink_Handoff[0]
BTSGSD-V2V-US-UpdateSessionAttributes|connect|module.BTSGSD-V2V-US-UpdateSessionAttributes[0]
silence_guard-dev|connect|module.silence_guard-dev[0]
conversion_of_queue_metrics|connect|module.conversion_of_queue_metrics[0]
lex_queueflow_callback|connect|module.lex_queueflow_callback[0]
lex_yesno|connect|module.lex_yesno[0]
BTSGSD-V2V-US-lex-QueueFlow-Callback|connect|module.lex_queueflow_callback[0]
BTSGSD-V2V-US-lex-yesNo|connect|module.lex_yesno[0]
iam-ctr|iam-ctr|module.iam-ctr[0]
s3_connect_reporting|s3_connect_reporting|module.s3_connect_reporting[0]
s3_intent_kb|btsgsd-intent-kb|module.s3_intent_kb[0]
secrets_manager|secrets_manager|module.secrets_manager[0]
queue_info_dynamodb|dynamodb|module.queue_info_dynamodb[0]
cloudwatch_log_group|cloudwatch_log_group|module.cloudwatch_log_group[0]
lex_yesno_log_group|cloudwatch_log_group|module.lex_yesno_log_group[0]
lex_bot|lex_bot|module.lex_bot[0]
lex_yesno_bot|lex_bot|module.lex_yesno_bot[0]
lex_customer_queue_flow_bot|lex_bot|module.lex_customer_queue_flow_bot[0]
lex_aiagent_survey_bot|lex_bot|module.lex_aiagent_survey_bot[0]
s3_v2v|v2v|module.s3_v2v[0]
cloudfront_v2v|v2v|module.cloudfront_v2v[0]
cognito_v2v|v2v|module.cognito_v2v[0]
iam_v2v|v2v|module.iam_v2v[0]
ssm_v2v|v2v|module.ssm_v2v[0]
V2V_CHOICES

if [ -z "$TERRAFORM_STATE_MODULE" ]; then
  echo "Unsupported V2V module: $DEPLOYMENT_TARGET" >&2
  return 1
fi

TERRAFORM_STATE_PATH="$TERRAFORM_STATE_MODULE"
# Retain each existing state when renaming pipeline choices and modules.
case "$TERRAFORM_STATE_MODULE" in
  btsgsd-v2v-us-snow)
    TERRAFORM_STATE_PATH=lambda-snow-btsgsd-dev
    ;;
  btsgsd-v2v-us-servicenow_interaction)
    TERRAFORM_STATE_PATH=lambda-servicenow-interaction
    ;;
  btsgsd-v2v-us-nextthink_handoff)
    TERRAFORM_STATE_PATH=lambda-nextthink-handoff
    ;;
esac

TERRAFORM_BACKEND_KEY="terraform-state/$DEPLOYMENT_ENVIRONMENT/$DEPLOYMENT_REGION/$TERRAFORM_STATE_PATH/terraform.tfstate"
TERRAFORM_PLAN_ARGS=(
  "-var=environment=$DEPLOYMENT_ENVIRONMENT"
  "-var=enabled_modules=[\"$TERRAFORM_STATE_MODULE\"]"
  "-var=snow_lambda_python_executable=python3"
  "-var=servicenow_interaction_python_executable=python3"
  "-var=nexthink_handoff_python_executable=python3"
  "-var=connect_flow_python_executable=python3"
  "-var=dev_ai_security_profile_python_executable=python3"
  "-var=dev_support_ai_python_executable=python3"
  "-var=dev_survey_ai_python_executable=python3"
)

# Apply executes the saved plan; targeting belongs on the Plan command.
if [ -n "$TERRAFORM_TARGET_ADDRESS" ]; then
  TERRAFORM_PLAN_ARGS+=("-target=$TERRAFORM_TARGET_ADDRESS")
fi

# The Connect invocation grant is owned by the root, outside the Lambda module.
if [ "$DEPLOYMENT_TARGET" = conversion_of_queue_metrics ]; then
  TERRAFORM_PLAN_ARGS+=("-target=aws_lambda_permission.queue_metrics_connect[0]")
fi

# Call after Terraform init to preserve an existing gateway audience.
preserve_v2v_target_outputs() {
  if [ "$TERRAFORM_STATE_MODULE" != connect ]; then
    return 0
  fi

  local outputs gateway_id
  outputs="$(terraform output -json)" || return 1
  gateway_id="$(python3 -c '
import json
import sys

output = json.load(sys.stdin)
gateway = (output.get("agentcore_gateway") or {}).get("value") or {}
print(gateway.get("id") or "")
' <<< "$outputs")" || return 1

  if [ -n "$gateway_id" ]; then
    TERRAFORM_PLAN_ARGS+=("-var=agentcore_gateway_id_audience=$gateway_id")
  fi
}

# Verify the saved plan uses the selected V2V environment and module group.
validate_v2v_target_plan() {
  terraform show -json "${1:-tfplan}" |
    python3 -c '
import json
import sys

plan = json.load(sys.stdin)
variables = plan.get("variables", {})
group, environment = sys.argv[1:3]

if variables.get("environment", {}).get("value") != environment:
    raise SystemExit("Plan environment does not match the V2V selection.")

if variables.get("enabled_modules", {}).get("value") != [group]:
    raise SystemExit("Plan module group does not match the V2V selection.")

prefix = ("module.connect_resources[0].", "module.external_vms[0].")
changes = [
    change for change in plan.get("resource_changes", [])
    if change.get("mode") == "managed"
    and change.get("change", {}).get("actions") != ["no-op"]
]

signing_prefixes = ("module.signing_profile[0].", "module.code_signing_config[0].")
if group == "code-signing":
    unexpected = [
        change["address"] for change in changes
        if not change["address"].startswith(signing_prefixes)
    ]
    if unexpected:
        raise SystemExit(
            "Refusing changes outside the code-signing modules: "
            + ", ".join(unexpected)
        )
else:
    misplaced = [
        change["address"] for change in changes
        if change["address"].startswith(signing_prefixes)
    ]
    if misplaced:
        raise SystemExit(
            "Move the signing modules into the dedicated code-signing state "
            "before applying another deployment group."
        )

if group == "connect-resources":
    unexpected = [
        change["address"] for change in changes
        if not change["address"].startswith(prefix)
    ]
    if unexpected:
        raise SystemExit(
            "Refusing changes outside connect_resources: "
            + ", ".join(unexpected)
            + ". Separate the existing Terraform state before applying."
        )

if group != "connect-resources":
    misplaced = [
        change["address"] for change in changes
        if change["address"].startswith(prefix)
    ]
    if misplaced:
        raise SystemExit(
            "Move connect_resources into its dedicated state before "
            "applying another deployment group."
        )

print("Validated V2V plan for group: " + group)
' "$TERRAFORM_STATE_MODULE" "$DEPLOYMENT_ENVIRONMENT"
}
