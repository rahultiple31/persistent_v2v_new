#!/usr/bin/env bash
# Sourced by both pipeline stages to select the existing Terraform state and args.

DEPLOYMENT_TARGET="${1:?Target module is required}"
DEPLOYMENT_ENVIRONMENT="${2:?Environment is required}"
DEPLOYMENT_REGION="${3:-us-east-1}"

case "$DEPLOYMENT_TARGET" in
  Connect_integrations|data_table|agentcore_gateway|ai_agent_tools|lambda-servicenow-interaction|lambda-nextthink-handoff|silence_guard-dev|UpdateSessionAttributes-dev)
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
  silence_guard-dev|UpdateSessionAttributes-dev)
    TERRAFORM_STATE_MODULE="connect"
    TERRAFORM_PLAN_ARGS=(
      '-var=enabled_modules=["connect"]'
      "-target=module.$DEPLOYMENT_TARGET"
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
