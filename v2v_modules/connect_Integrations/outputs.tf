output "deployment" {
  description = "Connect MCP integration and instance association."

  value = {
    display_name    = var.display_name
    type            = "MCP_SERVER"
    instance_arn    = var.connect_instance_arn
    gateway_id      = var.gateway_id
    gateway_url     = var.gateway_url
    application_id  = aws_cloudformation_stack.integration.outputs["ApplicationId"]
    application_arn = aws_cloudformation_stack.integration.outputs["ApplicationArn"]
    association_id  = aws_cloudformation_stack.integration.outputs["AssociationId"]
  }
}
