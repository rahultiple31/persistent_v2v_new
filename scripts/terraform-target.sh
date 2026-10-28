#!/usr/bin/env bash
# Sourced by both pipeline stages to select the existing Terraform state and args.

DEPLOYMENT_TARGET="${1:?Target module is required}"
DEPLOYMENT_ENVIRONMENT="${2:?Environment is required}"
DEPLOYMENT_REGION="${3:-us-east-1}"

case "$DEPLOYMENT_TARGET" in
  v2v)
    echo "V2V deployment is retired in dev and dev-nsso. Use prepare-destroy-v2v and destroy-v2v-stack." >&2
    return 1
    ;;
  dynamodb|connect-queue|Connect_integrations|data_table|agentcore_gateway|ai_agent_tools|delete-BTSGSD-SSO-US-AI-Survey-Agent|lambda-servicenow-interaction|lambda-nextthink-handoff|silence_guard-dev|UpdateSessionAttributes-dev|conversionOfQueueMetrics-dev|BTSGSD-lex-yesNo-dev|BTSGSD-lex-QueueFlow-Callback-dev)
    if [ "$DEPLOYMENT_ENVIRONMENT" != "dev" ]; then
      echo "$DEPLOYMENT_TARGET is supported only for dev." >&2
      return 1
    fi
    ;;
esac

TERRAFORM_STATE_MODULE="$DEPLOYMENT_TARGET"
TERRAFORM_PLAN_ARGS=(
  "-var=enabled_modules=[\"$DEPLOYMENT_TARGET\"]"
)

case "$DEPLOYMENT_TARGET" in
  prepare-destroy-v2v|destroy-v2v-stack)
    case "$DEPLOYMENT_ENVIRONMENT" in
      dev|dev-nsso) ;;
      *)
        echo "$DEPLOYMENT_TARGET supports only dev and dev-nsso." >&2
        return 1
        ;;
    esac

    TERRAFORM_STATE_MODULE="v2v"
    TERRAFORM_PLAN_ARGS=(
      '-var=enabled_modules=["v2v"]'
      '-var=force_destroy_v2v_buckets=true'
    )
    if [ "$DEPLOYMENT_TARGET" = "prepare-destroy-v2v" ]; then
      TERRAFORM_PLAN_ARGS+=('-var=destroy_v2v_stack=false')
    else
      TERRAFORM_PLAN_ARGS+=('-var=destroy_v2v_stack=true')
    fi
    ;;
  connect-queue)
    TERRAFORM_STATE_MODULE="connect"
    TERRAFORM_PLAN_ARGS=(
      '-var=enabled_modules=["connect"]'
      -target=module.connect_queue
    )
    ;;
  silence_guard-dev|UpdateSessionAttributes-dev|conversionOfQueueMetrics-dev|BTSGSD-lex-yesNo-dev|BTSGSD-lex-QueueFlow-Callback-dev)
    TERRAFORM_STATE_MODULE="connect"
    TERRAFORM_MODULE_NAME="$DEPLOYMENT_TARGET"

    case "$DEPLOYMENT_TARGET" in
      conversionOfQueueMetrics-dev) TERRAFORM_MODULE_NAME="conversion_of_queue_metrics" ;;
      BTSGSD-lex-yesNo-dev) TERRAFORM_MODULE_NAME="lex_yesno" ;;
      BTSGSD-lex-QueueFlow-Callback-dev) TERRAFORM_MODULE_NAME="lex_queueflow_callback" ;;
    esac

    TERRAFORM_PLAN_ARGS=(
      '-var=enabled_modules=["connect"]'
      "-target=module.$TERRAFORM_MODULE_NAME"
    )
    ;;
  delete-BTSGSD-SSO-US-AI-Survey-Agent)
    TERRAFORM_STATE_MODULE="connect"
    TERRAFORM_PLAN_ARGS=(
      '-var=enabled_modules=["connect"]'
      -target=module.BTSGSD-SSO-US-AI-Survey-Agent
    )
    ;;
  ai_agent_tools)
    TERRAFORM_STATE_MODULE="connect"
    TERRAFORM_PLAN_ARGS=(
      '-var=enabled_modules=["connect"]'
      -target=module.btsgsd_support_agent
    )
    ;;
  Connect_integrations)
    TERRAFORM_STATE_MODULE="connect"
    TERRAFORM_PLAN_ARGS=(
      '-var=enabled_modules=["connect"]'
      -target=module.connect_Integrations
    )
    ;;
  data_table)
    TERRAFORM_STATE_MODULE="connect"
    TERRAFORM_PLAN_ARGS=(
      '-var=enabled_modules=["connect"]'
      -target=aws_cloudformation_stack.customer_number_data_table
      -target=aws_cloudformation_stack.hr_transfer_data_table
      -target=aws_cloudformation_stack.survey_data_table
      -target=aws_cloudformation_stack.veeva_transfer_data_table
      -target=aws_cloudformation_stack.top_level_blocker_data_table
      -target=aws_cloudformation_stack.bts_gsd_customer_number_data_table
    )
    ;;
  agentcore_gateway)
    TERRAFORM_STATE_MODULE="connect"
    TERRAFORM_PLAN_ARGS=(
      '-var=enabled_modules=["connect"]'
      -target=module.agentcore_gateway
      -target=module.connect_Integrations
    )
    ;;
  lambda-servicenow-interaction)
    TERRAFORM_PLAN_ARGS+=(
      '-var=servicenow_interaction_python_executable=python3'
    )
    ;;
  lambda-nextthink-handoff)
    TERRAFORM_PLAN_ARGS+=(
      '-var=nexthink_handoff_python_executable=python3'
    )
    ;;
esac

TERRAFORM_BACKEND_KEY="terraform-state/$DEPLOYMENT_ENVIRONMENT/$DEPLOYMENT_REGION/$TERRAFORM_STATE_MODULE/terraform.tfstate"

validate_terraform_target_plan() {
  case "$DEPLOYMENT_TARGET" in
    prepare-destroy-v2v|destroy-v2v-stack)
      terraform show -json "${1:-tfplan}" |
        python3 "$(dirname "${BASH_SOURCE[0]}")/validate-dev-v2v-cleanup-plan.py" \
          "$DEPLOYMENT_TARGET" "$DEPLOYMENT_ENVIRONMENT" || return 1
      ;;
    delete-BTSGSD-SSO-US-AI-Survey-Agent)
      terraform show -json "${1:-tfplan}" |
        python3 -c '
import json
import sys

plan = json.load(sys.stdin)
prefix = "module.BTSGSD-SSO-US-AI-Survey-Agent["
deletions = []
for change in plan.get("resource_changes", []):
    actions = change["change"]["actions"]
    if actions in (["no-op"], ["read"]):
        continue
    address = change["address"]
    if not address.startswith(prefix) or actions != ["delete"]:
        print(f"Deletion plan rejected: {address}: {actions}", file=sys.stderr)
        sys.exit(1)
    deletions.append(address)
print(f"Validated survey-agent cleanup: {len(deletions)} resources to delete.")
' || return 1
      ;;
  esac
  return 0
}

preserve_terraform_target_outputs() {
  case "$DEPLOYMENT_TARGET" in
    connect|agentcore_gateway|Connect_integrations|ai_agent_tools)
      local gateway_audience_id
      gateway_audience_id="$(
        terraform output -json |
          python3 -c 'import json, sys; gateway = (json.load(sys.stdin).get("agentcore_gateway") or {}).get("value") or {}; print(gateway.get("id") or "")'
      )" || return 1

      if [ -n "$gateway_audience_id" ]; then
        TERRAFORM_PLAN_ARGS+=(
          "-var=agentcore_gateway_id_audience=$gateway_audience_id"
        )
      fi
      ;;
  esac
  return 0
}
