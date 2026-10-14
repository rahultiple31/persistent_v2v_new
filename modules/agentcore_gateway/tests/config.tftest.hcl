mock_provider "aws" {
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

variables {
  stack_name   = "btsgsd-dev-AgentCore-DefaultGateway"
  gateway_name = "gateway-quick-start-dev"
  role_name    = "btsgsd-dev-agentcore-default-gateway-role"
  lambda_arn   = "arn:aws:lambda:us-east-1:518902362956:function:SNOW_btsgsd-dev"
  connect_url  = "https://btsgsd-dev-us-east-1.my.connect.aws"
}

run "bootstrap_configuration" {
  command = plan

  plan_options {
    target = [aws_cloudformation_stack.gateway]
  }

  assert {
    condition = (
      aws_cloudformation_stack.gateway.name == "btsgsd-dev-AgentCore-DefaultGateway" &&
      aws_cloudformation_stack.gateway.parameters.GatewayAudience == "" &&
      jsondecode(aws_cloudformation_stack.gateway.template_body).Resources.Gateway.Properties.Name == "gateway-quick-start-dev" &&
      jsondecode(aws_cloudformation_stack.gateway.template_body).Resources.Gateway.Properties.ProtocolType == "MCP" &&
      jsondecode(aws_cloudformation_stack.gateway.template_body).Resources.Gateway.Properties.AuthorizerType == "CUSTOM_JWT" &&
      jsondecode(aws_cloudformation_stack.gateway.template_body).Resources.Gateway.Properties.AuthorizerConfiguration.CustomJWTAuthorizer.DiscoveryUrl == "https://btsgsd-dev-us-east-1.my.connect.aws/.well-known/openid-configuration"
    )
    error_message = "Bootstrap gateway-quick-start-dev with the requested Connect JWT discovery endpoint before its ID exists."
  }

  assert {
    condition = (
      local.gateway_template.Conditions.HasGatewayAudience["Fn::Not"][0]["Fn::Equals"] == [{ Ref = "GatewayAudience" }, ""] &&
      local.gateway_template.Resources.Gateway.Properties.AuthorizerConfiguration.CustomJWTAuthorizer.AllowedAudience["Fn::If"][2] == ["https://btsgsd-dev-us-east-1.my.connect.aws"] &&
      local.gateway_template.Resources.Gateway.Properties.AuthorizerConfiguration.CustomJWTAuthorizer.AllowedAudience["Fn::If"][1] == ["https://btsgsd-dev-us-east-1.my.connect.aws", { Ref = "GatewayAudience" }] &&
      !contains(keys(local.gateway_template.Resources.Gateway.Properties), "VpcConfiguration") &&
      !contains(keys(local.gateway_template.Resources.UserLookupTarget.Properties), "PrivateEndpoint")
    )
    error_message = "Select the Connect URL during bootstrap and both audiences once the ID is provided, with no VPC configuration."
  }

  assert {
    condition = (
      local.gateway_template.Resources.GatewayRole.Properties.AssumeRolePolicyDocument.Statement[0].Principal.Service == "bedrock-agentcore.amazonaws.com" &&
      local.gateway_template.Resources.GatewayRole.Properties.AssumeRolePolicyDocument.Statement[0].Condition.StringEquals["aws:SourceAccount"] == "518902362956" &&
      local.gateway_template.Resources.GatewayRole.Properties.AssumeRolePolicyDocument.Statement[0].Condition.ArnLike["aws:SourceArn"] == "arn:aws:bedrock-agentcore:us-east-1:518902362956:gateway/gateway-quick-start-dev-*" &&
      length(local.gateway_template.Resources.GatewayRole.Properties.Policies) == 1 &&
      length(local.gateway_template.Resources.GatewayRole.Properties.Policies[0].PolicyDocument.Statement) == 1 &&
      local.gateway_template.Resources.GatewayRole.Properties.Policies[0].PolicyDocument.Statement[0].Action == "lambda:InvokeFunction" &&
      local.gateway_template.Resources.GatewayRole.Properties.Policies[0].PolicyDocument.Statement[0].Resource == "arn:aws:lambda:us-east-1:518902362956:function:SNOW_btsgsd-dev" &&
      local.gateway_template.Resources.UserLookupTarget.Properties.CredentialProviderConfigurations[0].CredentialProviderType == "GATEWAY_IAM_ROLE" &&
      local.gateway_template.Resources.UserLookupTarget.Properties.TargetConfiguration.Mcp.Lambda.LambdaArn == "arn:aws:lambda:us-east-1:518902362956:function:SNOW_btsgsd-dev"
    )
    error_message = "Restrict gateway execution to the intended account, gateway-quick-start-dev and ServiceNow Lambda."
  }

  assert {
    condition = (
      length(local.gateway_template.Resources.UserLookupTarget.Properties.TargetConfiguration.Mcp.Lambda.ToolSchema.InlinePayload) == 1 &&
      local.gateway_template.Resources.UserLookupTarget.Properties.TargetConfiguration.Mcp.Lambda.ToolSchema.InlinePayload[0].Name == "UserLookUp" &&
      local.gateway_template.Resources.UserLookupTarget.Properties.TargetConfiguration.Mcp.Lambda.ToolSchema.InlinePayload[0].Description == local.userlookup_schema[0].description &&
      local.gateway_template.Resources.UserLookupTarget.Properties.TargetConfiguration.Mcp.Lambda.ToolSchema.InlinePayload[0].InputSchema.Type == "object" &&
      toset(keys(local.gateway_template.Resources.UserLookupTarget.Properties.TargetConfiguration.Mcp.Lambda.ToolSchema.InlinePayload[0].InputSchema.Properties)) == toset(["phone", "upi"]) &&
      alltrue([
        for name in ["phone", "upi"] :
        local.gateway_template.Resources.UserLookupTarget.Properties.TargetConfiguration.Mcp.Lambda.ToolSchema.InlinePayload[0].InputSchema.Properties[name].Type == "string" &&
        local.gateway_template.Resources.UserLookupTarget.Properties.TargetConfiguration.Mcp.Lambda.ToolSchema.InlinePayload[0].InputSchema.Properties[name].Description == local.userlookup_schema[0].inputSchema.properties[name].description
      ]) &&
      !contains(keys(local.gateway_template.Resources.UserLookupTarget.Properties.TargetConfiguration.Mcp.Lambda.ToolSchema.InlinePayload[0].InputSchema), "Required") &&
      strcontains(local.userlookup_schema[0].description, "Status (\"Authenticated\"/\"Unauthenticated\")") &&
      strcontains(local.userlookup_schema[0].description, "At most three UPI submissions per conversation")
    )
    error_message = "Preserve the supplied UserLookUp schema and optional phone/upi parameters when translating to CloudFormation casing."
  }
}

run "generated_gateway_id_audience" {
  command = apply

  variables {
    gateway_id_audience = "gateway-quick-start-dev-a1b2c3d4e5"
  }

  plan_options {
    target = [aws_cloudformation_stack.gateway]
  }

  assert {
    condition = (
      aws_cloudformation_stack.gateway.parameters.GatewayAudience == "gateway-quick-start-dev-a1b2c3d4e5" &&
      output.deployment.name == "gateway-quick-start-dev" &&
      output.deployment.id == "gateway-quick-start-dev-a1b2c3d4e5" &&
      output.deployment.arn == "arn:aws:bedrock-agentcore:us-east-1:518902362956:gateway/gateway-quick-start-dev-a1b2c3d4e5" &&
      output.deployment.url == "https://gateway-quick-start-dev-a1b2c3d4e5.gateway.bedrock-agentcore.us-east-1.amazonaws.com/mcp" &&
      local.gateway_template.Resources.GatewayRole.Properties.AssumeRolePolicyDocument.Statement[0].Condition.ArnLike["aws:SourceArn"] == "arn:aws:bedrock-agentcore:us-east-1:518902362956:gateway/gateway-quick-start-dev-a1b2c3d4e5" &&
      output.deployment.target_id == "target12345" &&
      output.deployment.tool_name == "snow-userlookup___UserLookUp"
    )
    error_message = "Use the actual generated ID as the second audience and export the gateway endpoint and tool identifiers."
  }
}

run "existing_gateway_id_remains_valid" {
  command = plan

  variables {
    gateway_id_audience = "default-a1b2c3d4e5"
  }

  plan_options {
    target = [aws_cloudformation_stack.gateway]
  }

  assert {
    condition = (
      local.gateway_template.Resources.Gateway.Properties.Name == "gateway-quick-start-dev" &&
      aws_cloudformation_stack.gateway.parameters.GatewayAudience == "default-a1b2c3d4e5" &&
      local.gateway_template.Resources.GatewayRole.Properties.AssumeRolePolicyDocument.Statement[0].Condition.ArnLike["aws:SourceArn"] == "arn:aws:bedrock-agentcore:us-east-1:518902362956:gateway/default-a1b2c3d4e5"
    )
    error_message = "Existing gateway IDs must remain valid for JWT authorization and exact IAM trust."
  }
}

run "literal_gateway_id_is_rejected" {
  command = plan

  variables {
    gateway_id_audience = "Gateway ID"
  }

  expect_failures = [var.gateway_id_audience]
}
