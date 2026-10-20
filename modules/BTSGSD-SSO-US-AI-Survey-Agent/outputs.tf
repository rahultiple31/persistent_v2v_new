output "agent_id" {
  value      = aws_cloudformation_stack.survey.outputs["AgentId"]
  depends_on = [terraform_data.admin_assignment]
}

output "agent_version_arn" {
  value      = local.agent_version_arn
  depends_on = [terraform_data.admin_assignment]
}
