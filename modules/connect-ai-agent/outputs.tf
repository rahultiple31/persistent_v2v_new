output "ai_agent_id" {
  value      = awscc_wisdom_ai_agent.survey_agent.ai_agent_id
  depends_on = [terraform_data.admin_assignment]
}

output "ai_agent_arn" {
  value      = local.agent_arn
  depends_on = [terraform_data.admin_assignment]
}

output "ai_agent_version_arn" {
  value      = local.agent_version_arn
  depends_on = [terraform_data.admin_assignment]
}
