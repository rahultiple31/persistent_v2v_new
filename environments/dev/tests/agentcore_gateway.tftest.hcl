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
    target = [aws_cloudformation_stack.agentcore_gateway]
  }

  assert {
    condition = (
      length(aws_cloudformation_stack.agentcore_gateway) == 1 &&
      aws_cloudformation_stack.agentcore_gateway[0].parameters.GatewayAudience == "" &&
      jsondecode(aws_cloudformation_stack.agentcore_gateway[0].template_body).Resources.Gateway.Properties.Name == "gateway-quick-start-dev" &&
      jsondecode(aws_cloudformation_stack.agentcore_gateway[0].template_body).Resources.Gateway.Properties.ProtocolType == "MCP" &&
      jsondecode(aws_cloudformation_stack.agentcore_gateway[0].template_body).Resources.Gateway.Properties.AuthorizerType == "CUSTOM_JWT" &&
      jsondecode(aws_cloudformation_stack.agentcore_gateway[0].template_body).Resources.Gateway.Properties.AuthorizerConfiguration.CustomJWTAuthorizer.DiscoveryUrl == "https://btsgsd-dev-us-east-1.my.connect.aws/.well-known/openid-configuration"
    )
    error_message = "Bootstrap gateway-quick-start-dev with the requested Connect JWT discovery endpoint before its ID exists."
  }

  assert {
    condition = (
      local.agentcore_gateway_template.Conditions.HasGatewayAudience["Fn::Not"][0]["Fn::Equals"] == [{ Ref = "GatewayAudience" }, ""] &&
      local.agentcore_gateway_template.Resources.Gateway.Properties.AuthorizerConfiguration.CustomJWTAuthorizer.AllowedAudience["Fn::If"][2] == ["https://btsgsd-dev-us-east-1.my.connect.aws"] &&
      local.agentcore_gateway_template.Resources.Gateway.Properties.AuthorizerConfiguration.CustomJWTAuthorizer.AllowedAudience["Fn::If"][1] == ["https://btsgsd-dev-us-east-1.my.connect.aws", { Ref = "GatewayAudience" }] &&
      !contains(keys(local.agentcore_gateway_template.Resources.Gateway.Properties), "VpcConfiguration") &&
      !contains(keys(local.agentcore_gateway_template.Resources.UserLookupTarget.Properties), "PrivateEndpoint")
    )
    error_message = "Select the Connect URL during bootstrap and both audiences once the ID is provided, with no VPC configuration."
  }

  assert {
    condition = (
      local.agentcore_gateway_template.Resources.GatewayRole.Properties.AssumeRolePolicyDocument.Statement[0].Principal.Service == "bedrock-agentcore.amazonaws.com" &&
      local.agentcore_gateway_template.Resources.GatewayRole.Properties.AssumeRolePolicyDocument.Statement[0].Condition.StringEquals["aws:SourceAccount"] == "518902362956" &&
      local.agentcore_gateway_template.Resources.GatewayRole.Properties.AssumeRolePolicyDocument.Statement[0].Condition.ArnLike["aws:SourceArn"] == "arn:aws:bedrock-agentcore:us-east-1:518902362956:gateway/gateway-quick-start-dev-*" &&
      length(local.agentcore_gateway_template.Resources.GatewayRole.Properties.Policies) == 1 &&
      length(local.agentcore_gateway_template.Resources.GatewayRole.Properties.Policies[0].PolicyDocument.Statement) == 1 &&
      local.agentcore_gateway_template.Resources.GatewayRole.Properties.Policies[0].PolicyDocument.Statement[0].Action == "lambda:InvokeFunction" &&
      local.agentcore_gateway_template.Resources.GatewayRole.Properties.Policies[0].PolicyDocument.Statement[0].Resource == "arn:aws:lambda:us-east-1:518902362956:function:SNOW_btsgsd-dev" &&
      local.agentcore_gateway_template.Resources.UserLookupTarget.Properties.CredentialProviderConfigurations[0].CredentialProviderType == "GATEWAY_IAM_ROLE" &&
      local.agentcore_gateway_template.Resources.UserLookupTarget.Properties.TargetConfiguration.Mcp.Lambda.LambdaArn == "arn:aws:lambda:us-east-1:518902362956:function:SNOW_btsgsd-dev"
    )
    error_message = "Restrict gateway execution to the intended account, gateway-quick-start-dev and ServiceNow Lambda."
  }

  assert {
    condition = (
      length(local.agentcore_gateway_template.Resources.UserLookupTarget.Properties.TargetConfiguration.Mcp.Lambda.ToolSchema.InlinePayload) == 1 &&
      local.agentcore_gateway_template.Resources.UserLookupTarget.Properties.TargetConfiguration.Mcp.Lambda.ToolSchema.InlinePayload[0].Name == "UserLookUp" &&
      local.agentcore_gateway_template.Resources.UserLookupTarget.Properties.TargetConfiguration.Mcp.Lambda.ToolSchema.InlinePayload[0].Description == local.agentcore_userlookup_schema[0].description &&
      local.agentcore_gateway_template.Resources.UserLookupTarget.Properties.TargetConfiguration.Mcp.Lambda.ToolSchema.InlinePayload[0].InputSchema.Type == "object" &&
      toset(keys(local.agentcore_gateway_template.Resources.UserLookupTarget.Properties.TargetConfiguration.Mcp.Lambda.ToolSchema.InlinePayload[0].InputSchema.Properties)) == toset(["phone", "upi"]) &&
      alltrue([
        for name in ["phone", "upi"] :
        local.agentcore_gateway_template.Resources.UserLookupTarget.Properties.TargetConfiguration.Mcp.Lambda.ToolSchema.InlinePayload[0].InputSchema.Properties[name].Type == "string" &&
        local.agentcore_gateway_template.Resources.UserLookupTarget.Properties.TargetConfiguration.Mcp.Lambda.ToolSchema.InlinePayload[0].InputSchema.Properties[name].Description == local.agentcore_userlookup_schema[0].inputSchema.properties[name].description
      ]) &&
      !contains(keys(local.agentcore_gateway_template.Resources.UserLookupTarget.Properties.TargetConfiguration.Mcp.Lambda.ToolSchema.InlinePayload[0].InputSchema), "Required") &&
      strcontains(local.agentcore_userlookup_schema[0].description, "Status (\"Authenticated\"/\"Unauthenticated\")") &&
      strcontains(local.agentcore_userlookup_schema[0].description, "At most three UPI submissions per conversation")
    )
    error_message = "Preserve the supplied UserLookUp schema and optional phone/upi parameters when translating to CloudFormation casing."
  }
}

run "generated_gateway_id_audience" {
  command = apply

  variables {
    agentcore_gateway_id_audience = "gateway-quick-start-dev-a1b2c3d4e5"
  }

  plan_options {
    target = [aws_cloudformation_stack.agentcore_gateway]
  }

  assert {
    condition = (
      aws_cloudformation_stack.agentcore_gateway[0].parameters.GatewayAudience == "gateway-quick-start-dev-a1b2c3d4e5" &&
      output.agentcore_gateway.name == "gateway-quick-start-dev" &&
      output.agentcore_gateway.id == "gateway-quick-start-dev-a1b2c3d4e5" &&
      output.agentcore_gateway.arn == "arn:aws:bedrock-agentcore:us-east-1:518902362956:gateway/gateway-quick-start-dev-a1b2c3d4e5" &&
      output.agentcore_gateway.url == "https://gateway-quick-start-dev-a1b2c3d4e5.gateway.bedrock-agentcore.us-east-1.amazonaws.com/mcp" &&
      local.agentcore_gateway_template.Resources.GatewayRole.Properties.AssumeRolePolicyDocument.Statement[0].Condition.ArnLike["aws:SourceArn"] == "arn:aws:bedrock-agentcore:us-east-1:518902362956:gateway/gateway-quick-start-dev-a1b2c3d4e5" &&
      output.agentcore_gateway.target_id == "target12345" &&
      output.agentcore_gateway.tool_name == "snow-userlookup___UserLookUp"
    )
    error_message = "Use the actual generated ID as the second audience and export the gateway endpoint and tool identifiers."
  }
}

run "existing_gateway_id_survives_rename" {
  command = plan

  variables {
    agentcore_gateway_id_audience = "default-a1b2c3d4e5"
  }

  plan_options {
    target = [aws_cloudformation_stack.agentcore_gateway]
  }

  assert {
    condition = (
      local.agentcore_gateway_template.Resources.Gateway.Properties.Name == "gateway-quick-start-dev" &&
      aws_cloudformation_stack.agentcore_gateway[0].parameters.GatewayAudience == "default-a1b2c3d4e5" &&
      local.agentcore_gateway_template.Resources.GatewayRole.Properties.AssumeRolePolicyDocument.Statement[0].Condition.ArnLike["aws:SourceArn"] == "arn:aws:bedrock-agentcore:us-east-1:518902362956:gateway/default-a1b2c3d4e5" &&
      local.agentcore_gateway_template.Resources.GatewayRole.Properties.RoleName == "btsgsd-dev-agentcore-default-gateway-role" &&
      aws_cloudformation_stack.agentcore_gateway[0].name == "btsgsd-dev-AgentCore-DefaultGateway"
    )
    error_message = "An existing Gateway ID must remain usable for JWT and exact IAM trust while updating the display name in the same stack."
  }
}

run "other_targets_exclude_gateway" {
  command = plan

  variables {
    enabled_modules = []
  }

  assert {
    condition     = length(aws_cloudformation_stack.agentcore_gateway) == 0 && output.agentcore_gateway == null
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
