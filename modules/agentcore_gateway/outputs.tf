output "deployment" {
  description = "AgentCore gateway identifiers and MCP endpoint."

  value = {
    name      = var.gateway_name
    id        = aws_cloudformation_stack.gateway.outputs["GatewayId"]
    arn       = aws_cloudformation_stack.gateway.outputs["GatewayArn"]
    url       = aws_cloudformation_stack.gateway.outputs["GatewayUrl"]
    target_id = aws_cloudformation_stack.gateway.outputs["TargetId"]
    tool_name = "snow-userlookup___UserLookUp"
  }
}
