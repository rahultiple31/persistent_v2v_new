mock_provider "aws" {
  mock_data "aws_cloudformation_stack" {
    defaults = {
      outputs = {
        GatewayId          = "registered-gateway-0123456789"
        AgentArn           = "arn:aws:wisdom:us-east-1:518902362956:ai-agent/assistant-id/support-agent-id"
        AgentVersionArn    = "arn:aws:wisdom:us-east-1:518902362956:ai-agent/assistant-id/support-agent-id:4"
        AgentVersion       = "4"
        ConnectInstanceArn = "arn:aws:connect:us-east-1:518902362956:instance/bcc989e5-cd9d-494f-9cd4-434f39ccc90e"
      }
    }
  }
}

variables {
  connect_instance_arn = "arn:aws:connect:us-east-1:518902362956:instance/bcc989e5-cd9d-494f-9cd4-434f39ccc90e"
}

run "existing_stacks_supply_access_configuration" {
  command = plan

  assert {
    condition = (
      data.aws_cloudformation_stack.gateway.name == "BTSGSD-V2V-US-AgentCore-DefaultGateway" &&
      data.aws_cloudformation_stack.support_agent.name == "BTSGSD-V2V-US-SupportAgent" &&
      terraform_data.admin_mcp_access.input.namespace == "registered-gateway-0123456789" &&
      terraform_data.admin_mcp_access.input.connect_instance_arn == var.connect_instance_arn &&
      toset(terraform_data.admin_mcp_access.input.agent_arns) == toset([
        "arn:aws:wisdom:us-east-1:518902362956:ai-agent/assistant-id/support-agent-id",
        "arn:aws:wisdom:us-east-1:518902362956:ai-agent/assistant-id/support-agent-id:4",
      ]) &&
      toset(terraform_data.admin_mcp_access.input.tool_names) == toset([
        "BTSGSD-V2V-US-nexthink-handoff___handoff",
        "BTSGSD-V2V-US-snow-interaction___Interaction__Interaction",
        "BTSGSD-V2V-US-snow-userlookup___UserLookUp___UserLookUp",
      ])
    )
    error_message = "Access must use existing stack outputs and the exact three MCP tool names."
  }
}

run "different_connect_instance_is_rejected" {
  command = plan
  variables {
    connect_instance_arn = "arn:aws:connect:us-east-1:518902362956:instance/11111111-2222-3333-4444-555555555555"
  }
  expect_failures = [terraform_data.admin_mcp_access]
}

run "current_stack_outputs_control_gateway_and_agent_version" {
  command = plan

  override_data {
    target = data.aws_cloudformation_stack.gateway
    values = {
      outputs = { GatewayId = "another-gateway-9876543210" }
    }
  }

  override_data {
    target = data.aws_cloudformation_stack.support_agent
    values = {
      outputs = {
        AgentArn           = "arn:aws:wisdom:us-east-1:518902362956:ai-agent/assistant-id/support-agent-id"
        AgentVersionArn    = "arn:aws:wisdom:us-east-1:518902362956:ai-agent/assistant-id/support-agent-id:5"
        AgentVersion       = "5"
        ConnectInstanceArn = "arn:aws:connect:us-east-1:518902362956:instance/bcc989e5-cd9d-494f-9cd4-434f39ccc90e"
      }
    }
  }

  assert {
    condition = (
      terraform_data.admin_mcp_access.input.namespace == "another-gateway-9876543210" &&
      contains(terraform_data.admin_mcp_access.input.agent_arns, "arn:aws:wisdom:us-east-1:518902362956:ai-agent/assistant-id/support-agent-id:5")
    )
    error_message = "Use the registered gateway and current published version rather than hard-coded identifiers."
  }
}

run "latest_stack_qualifier_is_removed_and_published_arn_is_rebuilt" {
  command = plan

  override_data {
    target = data.aws_cloudformation_stack.support_agent
    values = {
      outputs = {
        AgentArn           = "arn:aws:wisdom:us-east-1:518902362956:ai-agent/assistant-id/support-agent-id:$LATEST"
        AgentVersionArn    = "arn:aws:wisdom:us-east-1:518902362956:ai-agent/assistant-id/support-agent-id:$LATEST:7"
        AgentVersion       = "7"
        ConnectInstanceArn = "arn:aws:connect:us-east-1:518902362956:instance/bcc989e5-cd9d-494f-9cd4-434f39ccc90e"
      }
    }
  }

  assert {
    condition = toset(terraform_data.admin_mcp_access.input.agent_arns) == toset([
      "arn:aws:wisdom:us-east-1:518902362956:ai-agent/assistant-id/support-agent-id",
      "arn:aws:wisdom:us-east-1:518902362956:ai-agent/assistant-id/support-agent-id:7",
    ])
    error_message = "Normalize the stack's :$LATEST output and build the published ARN from AgentVersion."
  }
}
