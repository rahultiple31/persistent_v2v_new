output "deployment" {
  description = "AgentCore gateway identifiers and MCP endpoint."

  value = {
    name      = var.gateway_name
    id        = aws_cloudformation_stack.gateway.outputs["GatewayId"]
    arn       = aws_cloudformation_stack.gateway.outputs["GatewayArn"]
    url       = aws_cloudformation_stack.gateway.outputs["GatewayUrl"]
    target_id = aws_cloudformation_stack.gateway.outputs["TargetId"]
    tool_name = "BTSGSD-V2V-US-snow-userlookup___${local.userlookup_schema[0].name}"
    interaction_target_id = var.interaction_lambda_arn == null ? null : try(
      aws_cloudformation_stack.gateway.outputs["InteractionTargetId"],
      null
    )
    interaction_tool_name = var.interaction_lambda_arn == null ? null : "BTSGSD-V2V-US-snow-interaction___${local.interaction_schema[0].name}"
    nexthink_target_id = var.nexthink_lambda_arn == null ? null : try(
      aws_cloudformation_stack.gateway.outputs["NexthinkTargetId"],
      null
    )
    nexthink_tool_name = var.nexthink_lambda_arn == null ? null : "BTSGSD-V2V-US-nexthink-handoff___${local.nexthink_schema[0].name}"
  }
}
