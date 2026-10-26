mock_provider "aws" {}

mock_provider "aws" {
  alias = "us_east_1"

  mock_data "aws_connect_instance" {
    defaults = {
      id  = "bcc989e5-cd9d-494f-9cd4-434f39ccc90e"
      arn = "arn:aws:connect:us-east-1:518902362956:instance/bcc989e5-cd9d-494f-9cd4-434f39ccc90e"
    }
  }

  mock_data "aws_cloudformation_stack" {
    defaults = {
      outputs = {
        GatewayId          = "registered-gateway-0123456789"
        AgentArn           = "arn:aws:wisdom:us-east-1:518902362956:ai-agent/assistant-id/support-agent-id"
        AgentVersionArn    = "arn:aws:wisdom:us-east-1:518902362956:ai-agent/assistant-id/support-agent-id:4"
        ConnectInstanceArn = "arn:aws:connect:us-east-1:518902362956:instance/bcc989e5-cd9d-494f-9cd4-434f39ccc90e"
      }
    }
  }
}

mock_provider "awscc" {
  alias = "us_east_1"
}
mock_provider "archive" {}
mock_provider "external" {}

run "tools_access_choice_reads_existing_stacks_without_vmx3_inputs" {
  command = plan

  variables {
    environment             = "v2v"
    enabled_modules         = ["connect"]
    translation_enabled     = false
    cognito_domain_prefix   = "tools-access-test"
    connect_instance_url    = "https://btsgsd-dev-v2v-poc-us-east-1.my.connect.aws"
    connect_instance_region = "us-east-1"
    connect_instance_alias  = "btsgsd-dev-v2v-poc-us-east-1"
  }

  plan_options {
    target = [module.btsgsd_support_agent_tools_access[0]]
  }

  assert {
    condition     = data.aws_connect_instance.target[0].id == "bcc989e5-cd9d-494f-9cd4-434f39ccc90e"
    error_message = "The access choice must resolve the selected existing V2V instance."
  }
}
