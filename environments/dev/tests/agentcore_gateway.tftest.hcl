mock_provider "aws" {}

mock_provider "aws" {
  alias = "us_east_1"

  mock_resource "aws_cloudformation_stack" {
    defaults = {
      outputs = {
        GatewayId  = "gateway-quick-start-dev-a1b2c3d4e5"
        GatewayArn = "arn:aws:bedrock-agentcore:us-east-1:518902362956:gateway/gateway-quick-start-dev-a1b2c3d4e5"
        GatewayUrl = "https://gateway-quick-start-dev-a1b2c3d4e5.gateway.bedrock-agentcore.us-east-1.amazonaws.com/mcp"
        TargetId   = "target12345"
      }
    }
  }
}

mock_provider "aws" {
  alias = "proxy_us_east_1"
}

mock_provider "external" {}

variables {
  agentcore_gateway_enabled             = true
  enabled_modules                       = ["connect"]
  cognito_domain_prefix                 = "agentcore-gateway-test"
  connect_instance_url                  = "https://btsgsd-dev-us-east-1.my.connect.aws"
  connect_instance_region               = "us-east-1"
  connect_admin_user_enabled            = false
  dev_ai_domain_enabled                 = false
  dev_ai_agent_enabled                  = false
  dev_support_ai_agent_enabled          = false
  dev_survey_ai_agent_enabled           = false
  dev_ai_admin_security_profile_enabled = false
}

run "bootstrap_configuration" {
  command = plan

  plan_options {
    target = [module.agentcore_gateway]
  }

  assert {
    condition     = length(module.agentcore_gateway) == 1
    error_message = "Enable the gateway module only for the selected Dev Connect deployment."
  }
}

run "generated_gateway_id_audience" {
  command = apply

  variables {
    agentcore_gateway_id_audience = "gateway-quick-start-dev-a1b2c3d4e5"
  }

  plan_options {
    target = [module.agentcore_gateway]
  }

  assert {
    condition = (
      output.agentcore_gateway.name == "gateway-quick-start-dev" &&
      output.agentcore_gateway.id == "gateway-quick-start-dev-a1b2c3d4e5" &&
      output.agentcore_gateway.arn == "arn:aws:bedrock-agentcore:us-east-1:518902362956:gateway/gateway-quick-start-dev-a1b2c3d4e5" &&
      output.agentcore_gateway.url == "https://gateway-quick-start-dev-a1b2c3d4e5.gateway.bedrock-agentcore.us-east-1.amazonaws.com/mcp" &&
      output.agentcore_gateway.target_id == "target12345" &&
      output.agentcore_gateway.tool_name == "snow-userlookup___UserLookUp"
    )
    error_message = "Preserve the root output contract after extracting the gateway module."
  }
}

run "gateway_can_be_disabled" {
  command = plan

  variables {
    agentcore_gateway_enabled = false
  }

  plan_options {
    target = [module.agentcore_gateway]
  }

  assert {
    condition     = length(module.agentcore_gateway) == 0 && output.agentcore_gateway == null
    error_message = "Disabling the gateway must remove its module while Connect remains enabled."
  }
}

run "existing_gateway_id_remains_valid" {
  command = plan

  variables {
    agentcore_gateway_id_audience = "default-a1b2c3d4e5"
  }

  plan_options {
    target = [module.agentcore_gateway]
  }

  assert {
    condition     = length(module.agentcore_gateway) == 1
    error_message = "Existing gateway IDs must remain accepted by the root module configuration."
  }
}

run "other_targets_exclude_gateway" {
  command = plan

  variables {
    enabled_modules = []
  }

  assert {
    condition     = length(module.agentcore_gateway) == 0 && output.agentcore_gateway == null
    error_message = "Gateway creation must be limited to the Dev Connect configuration."
  }
}

run "literal_gateway_id_is_rejected" {
  command = plan

  variables {
    enabled_modules               = []
    agentcore_gateway_id_audience = "Gateway ID"
  }

  expect_failures = [var.agentcore_gateway_id_audience]
}
