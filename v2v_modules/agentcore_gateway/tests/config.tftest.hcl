mock_provider "aws" {
  mock_resource "aws_cloudformation_stack" {
    defaults = {
      outputs = {
        GatewayId           = "btsgsd-v2v-us-gateway-quick-start-a1b2c3d4e5"
        GatewayArn          = "arn:aws:bedrock-agentcore:us-east-1:518902362956:gateway/btsgsd-v2v-us-gateway-quick-start-a1b2c3d4e5"
        GatewayUrl          = "https://btsgsd-v2v-us-gateway-quick-start-a1b2c3d4e5.gateway.bedrock-agentcore.us-east-1.amazonaws.com/mcp"
        TargetId            = "target12345"
        InteractionTargetId = "interaction67890"
      }
    }
  }
}

variables {
  stack_name   = "BTSGSD-V2V-US-AgentCore-DefaultGateway"
  gateway_name = "BTSGSD-V2V-US-gateway-quick-start"
  role_name    = "BTSGSD-V2V-US-agentcore-default-gateway-role"
  lambda_arn   = "arn:aws:lambda:us-east-1:518902362956:function:BTSGSD-V2V-US-SNOW"
  connect_url  = "https://btsgsd-dev-v2v-poc-us-east-1.my.connect.aws"
}

run "bootstrap_configuration" {
  command = plan

  plan_options {
    target = [aws_cloudformation_stack.gateway]
  }

  assert {
    condition = (
      !contains(keys(local.gateway_template.Resources), "InteractionTarget") &&
      !contains(keys(local.gateway_template.Outputs), "InteractionTargetId")
    )
    error_message = "Omit the optional target and its CloudFormation output when no Interaction Lambda is configured."
  }

  assert {
    condition = (
      aws_cloudformation_stack.gateway.name == "BTSGSD-V2V-US-AgentCore-DefaultGateway" &&
      aws_cloudformation_stack.gateway.parameters.GatewayAudience == "" &&
      jsondecode(aws_cloudformation_stack.gateway.template_body).Resources.Gateway.Properties.Name == "BTSGSD-V2V-US-gateway-quick-start" &&
      jsondecode(aws_cloudformation_stack.gateway.template_body).Resources.Gateway.Properties.ProtocolType == "MCP" &&
      jsondecode(aws_cloudformation_stack.gateway.template_body).Resources.Gateway.Properties.AuthorizerType == "CUSTOM_JWT" &&
      jsondecode(aws_cloudformation_stack.gateway.template_body).Resources.Gateway.Properties.AuthorizerConfiguration.CustomJWTAuthorizer.DiscoveryUrl == "https://btsgsd-dev-v2v-poc-us-east-1.my.connect.aws/.well-known/openid-configuration"
    )
    error_message = "Bootstrap gateway-quick-start with the requested Connect JWT discovery endpoint before its ID exists."
  }

  assert {
    condition = (
      local.gateway_template.Conditions.HasGatewayAudience["Fn::Not"][0]["Fn::Equals"] == [{ Ref = "GatewayAudience" }, ""] &&
      local.gateway_template.Resources.Gateway.Properties.AuthorizerConfiguration.CustomJWTAuthorizer.AllowedAudience["Fn::If"][2] == ["https://btsgsd-dev-v2v-poc-us-east-1.my.connect.aws"] &&
      local.gateway_template.Resources.Gateway.Properties.AuthorizerConfiguration.CustomJWTAuthorizer.AllowedAudience["Fn::If"][1] == ["https://btsgsd-dev-v2v-poc-us-east-1.my.connect.aws", { Ref = "GatewayAudience" }] &&
      !contains(keys(local.gateway_template.Resources.Gateway.Properties), "VpcConfiguration") &&
      !contains(keys(local.gateway_template.Resources.UserLookupTarget.Properties), "PrivateEndpoint")
    )
    error_message = "Select the Connect URL during bootstrap and both audiences once the ID is provided, with no VPC configuration."
  }

  assert {
    condition = (
      local.gateway_template.Resources.GatewayRole.Properties.AssumeRolePolicyDocument.Statement[0].Principal.Service == "bedrock-agentcore.amazonaws.com" &&
      local.gateway_template.Resources.GatewayRole.Properties.AssumeRolePolicyDocument.Statement[0].Condition.StringEquals["aws:SourceAccount"] == "518902362956" &&
      local.gateway_template.Resources.GatewayRole.Properties.AssumeRolePolicyDocument.Statement[0].Condition.ArnLike["aws:SourceArn"] == "arn:aws:bedrock-agentcore:us-east-1:518902362956:gateway/btsgsd-v2v-us-gateway-quick-start-*" &&
      length(local.gateway_template.Resources.GatewayRole.Properties.Policies) == 1 &&
      length(local.gateway_template.Resources.GatewayRole.Properties.Policies[0].PolicyDocument.Statement) == 1 &&
      local.gateway_template.Resources.GatewayRole.Properties.Policies[0].PolicyDocument.Statement[0].Action == "lambda:InvokeFunction" &&
      local.gateway_template.Resources.GatewayRole.Properties.Policies[0].PolicyDocument.Statement[0].Resource == "arn:aws:lambda:us-east-1:518902362956:function:BTSGSD-V2V-US-SNOW" &&
      local.gateway_template.Resources.UserLookupTarget.Properties.CredentialProviderConfigurations[0].CredentialProviderType == "GATEWAY_IAM_ROLE" &&
      local.gateway_template.Resources.UserLookupTarget.Properties.TargetConfiguration.Mcp.Lambda.LambdaArn == "arn:aws:lambda:us-east-1:518902362956:function:BTSGSD-V2V-US-SNOW"
    )
    error_message = "Restrict gateway execution to the intended account, gateway-quick-start and ServiceNow Lambda."
  }

  assert {
    condition = (
      length(local.gateway_template.Resources.UserLookupTarget.Properties.TargetConfiguration.Mcp.Lambda.ToolSchema.InlinePayload) == 1 &&
      local.gateway_template.Resources.UserLookupTarget.Properties.TargetConfiguration.Mcp.Lambda.ToolSchema.InlinePayload[0].Name == "UserLookUp___UserLookUp" &&
      local.gateway_template.Resources.UserLookupTarget.Properties.TargetConfiguration.Mcp.Lambda.ToolSchema.InlinePayload[0].Description == local.userlookup_schema[0].description &&
      local.gateway_template.Resources.UserLookupTarget.Properties.TargetConfiguration.Mcp.Lambda.ToolSchema.InlinePayload[0].InputSchema.Type == "object" &&
      toset(keys(local.gateway_template.Resources.UserLookupTarget.Properties.TargetConfiguration.Mcp.Lambda.ToolSchema.InlinePayload[0].InputSchema.Properties)) == toset(["upi"]) &&
      alltrue([
        for name in ["upi"] :
        local.gateway_template.Resources.UserLookupTarget.Properties.TargetConfiguration.Mcp.Lambda.ToolSchema.InlinePayload[0].InputSchema.Properties[name].Type == "string" &&
        local.gateway_template.Resources.UserLookupTarget.Properties.TargetConfiguration.Mcp.Lambda.ToolSchema.InlinePayload[0].InputSchema.Properties[name].Description == local.userlookup_schema[0].inputSchema.properties[name].description
      ]) &&
      local.gateway_template.Resources.UserLookupTarget.Properties.TargetConfiguration.Mcp.Lambda.ToolSchema.InlinePayload[0].InputSchema.Required == ["upi"] &&
      strcontains(local.userlookup_schema[0].description, "Flow owns phone; NEVER send phone.") &&
      strcontains(local.userlookup_schema[0].description, "Max three confirmed submissions.") &&
      strcontains(local.userlookup_schema[0].description, "(UPI-only release)")
    )
    error_message = "Preserve the supplied UPI-only schema name, required upi field, and bot instructions when translating to CloudFormation casing."
  }
}

run "generated_gateway_id_audience" {
  command = apply

  variables {
    gateway_id_audience = "btsgsd-v2v-us-gateway-quick-start-a1b2c3d4e5"
  }

  plan_options {
    target = [aws_cloudformation_stack.gateway]
  }

  assert {
    condition = (
      aws_cloudformation_stack.gateway.parameters.GatewayAudience == "btsgsd-v2v-us-gateway-quick-start-a1b2c3d4e5" &&
      output.deployment.name == "BTSGSD-V2V-US-gateway-quick-start" &&
      output.deployment.id == "btsgsd-v2v-us-gateway-quick-start-a1b2c3d4e5" &&
      output.deployment.arn == "arn:aws:bedrock-agentcore:us-east-1:518902362956:gateway/btsgsd-v2v-us-gateway-quick-start-a1b2c3d4e5" &&
      output.deployment.url == "https://btsgsd-v2v-us-gateway-quick-start-a1b2c3d4e5.gateway.bedrock-agentcore.us-east-1.amazonaws.com/mcp" &&
      local.gateway_template.Resources.GatewayRole.Properties.AssumeRolePolicyDocument.Statement[0].Condition.ArnLike["aws:SourceArn"] == "arn:aws:bedrock-agentcore:us-east-1:518902362956:gateway/btsgsd-v2v-us-gateway-quick-start-a1b2c3d4e5" &&
      output.deployment.target_id == "target12345" &&
      output.deployment.tool_name == "BTSGSD-V2V-US-snow-userlookup___UserLookUp___UserLookUp" &&
      output.deployment.interaction_target_id == null &&
      output.deployment.interaction_tool_name == null
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
      local.gateway_template.Resources.Gateway.Properties.Name == "BTSGSD-V2V-US-gateway-quick-start" &&
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

run "interaction_target_configuration" {
  command = plan

  variables {
    interaction_lambda_arn = "arn:aws:lambda:us-east-1:518902362956:function:BTSGSD-V2V-US-ServiceNow_Interaction"
  }

  assert {
    condition = (
      toset(keys(local.gateway_template.Resources)) == toset(["GatewayRole", "Gateway", "UserLookupTarget", "InteractionTarget"]) &&
      local.gateway_template.Resources.UserLookupTarget.Properties.TargetConfiguration.Mcp.Lambda.LambdaArn == "arn:aws:lambda:us-east-1:518902362956:function:BTSGSD-V2V-US-SNOW" &&
      local.gateway_template.Resources.InteractionTarget.Type == "AWS::BedrockAgentCore::GatewayTarget" &&
      local.gateway_template.Resources.InteractionTarget.DependsOn == ["GatewayRole"] &&
      local.gateway_template.Resources.InteractionTarget.Properties.Name == "BTSGSD-V2V-US-snow-interaction" &&
      local.gateway_template.Resources.InteractionTarget.Properties.GatewayIdentifier.Ref == "Gateway" &&
      local.gateway_template.Resources.InteractionTarget.Properties.CredentialProviderConfigurations[0].CredentialProviderType == "GATEWAY_IAM_ROLE" &&
      local.gateway_template.Resources.InteractionTarget.Properties.TargetConfiguration.Mcp.Lambda.LambdaArn == "arn:aws:lambda:us-east-1:518902362956:function:BTSGSD-V2V-US-ServiceNow_Interaction"
    )
    error_message = "Add the second MCP Lambda target to the existing gateway after its role permissions are updated."
  }

  assert {
    condition = (
      length(local.gateway_template.Resources.GatewayRole.Properties.Policies) == 2 &&
      local.gateway_template.Resources.GatewayRole.Properties.Policies[0].PolicyDocument.Statement[0].Resource == "arn:aws:lambda:us-east-1:518902362956:function:BTSGSD-V2V-US-SNOW" &&
      local.gateway_template.Resources.GatewayRole.Properties.Policies[1].PolicyName == "BTSGSD-V2V-US-InvokeServiceNowInteraction" &&
      length(local.gateway_template.Resources.GatewayRole.Properties.Policies[1].PolicyDocument.Statement) == 1 &&
      local.gateway_template.Resources.GatewayRole.Properties.Policies[1].PolicyDocument.Statement[0].Action == "lambda:InvokeFunction" &&
      local.gateway_template.Resources.GatewayRole.Properties.Policies[1].PolicyDocument.Statement[0].Resource == "arn:aws:lambda:us-east-1:518902362956:function:BTSGSD-V2V-US-ServiceNow_Interaction"
    )
    error_message = "Limit the new invoke permission to the specified Interaction Lambda and retain lookup permission."
  }

  assert {
    condition = (
      length(local.gateway_template.Resources.InteractionTarget.Properties.TargetConfiguration.Mcp.Lambda.ToolSchema.InlinePayload) == 1 &&
      local.gateway_template.Resources.InteractionTarget.Properties.TargetConfiguration.Mcp.Lambda.ToolSchema.InlinePayload[0].Name == "Interaction__Interaction" &&
      local.gateway_template.Resources.InteractionTarget.Properties.TargetConfiguration.Mcp.Lambda.ToolSchema.InlinePayload[0].Description == local.interaction_schema[0].description &&
      local.gateway_template.Resources.InteractionTarget.Properties.TargetConfiguration.Mcp.Lambda.ToolSchema.InlinePayload[0].InputSchema.Type == "object" &&
      toset(keys(local.gateway_template.Resources.InteractionTarget.Properties.TargetConfiguration.Mcp.Lambda.ToolSchema.InlinePayload[0].InputSchema.Properties)) == toset(["contactId", "description", "shortDescription", "upi"]) &&
      alltrue([
        for name in ["contactId", "description", "shortDescription", "upi"] :
        local.gateway_template.Resources.InteractionTarget.Properties.TargetConfiguration.Mcp.Lambda.ToolSchema.InlinePayload[0].InputSchema.Properties[name].Type == "string" &&
        local.gateway_template.Resources.InteractionTarget.Properties.TargetConfiguration.Mcp.Lambda.ToolSchema.InlinePayload[0].InputSchema.Properties[name].Description == local.interaction_schema[0].inputSchema.properties[name].description
      ]) &&
      local.gateway_template.Resources.InteractionTarget.Properties.TargetConfiguration.Mcp.Lambda.ToolSchema.InlinePayload[0].InputSchema.Required == ["upi", "contactId"] &&
      local.gateway_template.Outputs.InteractionTargetId.Value["Fn::GetAtt"] == ["InteractionTarget", "TargetId"]
    )
    error_message = "Translate the supplied Interaction schema and export the new target ID without altering field names or required inputs."
  }
}

run "interaction_target_outputs" {
  command = apply

  variables {
    interaction_lambda_arn = "arn:aws:lambda:us-east-1:518902362956:function:BTSGSD-V2V-US-ServiceNow_Interaction"
  }

  assert {
    condition = (
      output.deployment.interaction_target_id == "interaction67890" &&
      output.deployment.interaction_tool_name == "BTSGSD-V2V-US-snow-interaction___Interaction__Interaction" &&
      output.deployment.target_id == "target12345" &&
      output.deployment.tool_name == "BTSGSD-V2V-US-snow-userlookup___UserLookUp___UserLookUp"
    )
    error_message = "Export both targets' identifiers and MCP tool names."
  }
}
