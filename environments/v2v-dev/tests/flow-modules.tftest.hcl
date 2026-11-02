mock_provider "aws" {}
mock_provider "aws" { alias = "us_east_1" }
mock_provider "awscc" { alias = "us_east_1" }
mock_provider "archive" {}
mock_provider "external" {}

run "other_groups_do_not_require_flow_inputs" {
  command = plan
  variables {
    environment             = "v2v"
    enabled_modules         = ["lambda"]
    translation_enabled     = false
    cognito_domain_prefix   = "flow-module-test"
    connect_instance_url    = "https://btsgsd-dev-v2v-poc-us-east-1.my.connect.aws"
    connect_instance_region = "us-east-1"
  }
  plan_options {
    target = [module.aiagent_survey_flow, module.agent_to_agent_transfer_flow, module.outbound_whisper_flow, module.customer_queue_flow, module.abbvie_views]
  }
  assert {
    condition = (
      length(module.aiagent_survey_flow) == 0 &&
      length(module.agent_to_agent_transfer_flow) == 0 &&
      length(module.outbound_whisper_flow) == 0 &&
      length(module.customer_queue_flow) == 0 &&
      length(module.abbvie_views) == 0
    )
    error_message = "Non-Connect groups must not instantiate flows or index empty Connect modules."
  }
}
