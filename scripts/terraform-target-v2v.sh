#!/usr/bin/env bash
# Dedicated V2V selector; source this file from v2v-azure-pipeline.yml.
# Each module choice deploys its complete owning state group, one group per run.
# This script is independent of scripts/terraform-target.sh.

DEPLOYMENT_TARGET="${1:?V2V target module is required}"
DEPLOYMENT_ENVIRONMENT="${2:-v2v}"
DEPLOYMENT_REGION="${3:-us-east-1}"

if [ "$DEPLOYMENT_ENVIRONMENT" != v2v ] ||
   [ "$DEPLOYMENT_REGION" != us-east-1 ]; then
  echo "This selector supports only v2v in us-east-1." >&2
  return 1
fi

case "$DEPLOYMENT_TARGET" in
  connect-resources)
    # Deploy the complete Connect group, including connect_resources,
    # using its existing Terraform state.
    TERRAFORM_STATE_MODULE=connect
    ;;
  connect|connect_us_east_1|btsgsd-Main-IB-Flow|connect_views|abbvie_views|connect_queue|support_agent_tools|btsgsd_support_agent|btsgsd_ai_survey_agent|survey_ai_prompt|connect_ai_agent|agentcore_gateway|connect_Integrations|UpdateSessionAttributes-dev|silence_guard-dev|conversion_of_queue_metrics|lex_queueflow_callback|lex_yesno)
    TERRAFORM_STATE_MODULE=connect
    ;;
  lambda|lambda_us_east_1)
    TERRAFORM_STATE_MODULE=lambda
    ;;
  v2v|s3_v2v|cloudfront_v2v|cognito_v2v|iam_v2v|ssm_v2v)
    TERRAFORM_STATE_MODULE=v2v
    ;;
  dynamodb|queue_info_dynamodb)
    TERRAFORM_STATE_MODULE=dynamodb
    ;;
  btsgsd-intent-kb|s3_intent_kb)
    TERRAFORM_STATE_MODULE=btsgsd-intent-kb
    ;;
  lex_bot|lex_yesno_bot|lex_customer_queue_flow_bot|lex_aiagent_survey_bot)
    TERRAFORM_STATE_MODULE=lex_bot
    ;;
  secrets_manager|s3_connect_reporting|lambda-ctr-survey|lambda-connect-daily-ctr-export|lambda-ctr-raw|lambda-snow-btsgsd-dev|lambda-servicenow-interaction|lambda-nextthink-handoff|iam-ctr|cloudwatch_log_group)
    TERRAFORM_STATE_MODULE="$DEPLOYMENT_TARGET"
    ;;
  *)
    echo "Unsupported V2V module: $DEPLOYMENT_TARGET" >&2
    return 1
    ;;
esac

TERRAFORM_BACKEND_KEY="terraform-state/$DEPLOYMENT_ENVIRONMENT/$DEPLOYMENT_REGION/$TERRAFORM_STATE_MODULE/terraform.tfstate"
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

print("Validated V2V plan for group: " + group)
' "$TERRAFORM_STATE_MODULE" "$DEPLOYMENT_ENVIRONMENT"
}
