output "deployment" {
  description = "Published prompt and agent identifiers, including the versioned ARN for voice routing."
  value       = aws_cloudformation_stack.agent.outputs
  depends_on  = [terraform_data.retrieval_security_profile]
}

output "agent_version_arn" {
  value      = aws_cloudformation_stack.agent.outputs["AgentVersionArn"]
  depends_on = [terraform_data.retrieval_security_profile]
}

output "retrieval_security_profile_id" {
  description = "Security profile granting Retrieve access on the draft and published AI agent."
  value       = aws_connect_security_profile.retrieval.security_profile_id
  depends_on  = [terraform_data.retrieval_security_profile]
}

output "test_question" {
  description = "Test metadata from the custom YAML, excluded from the model prompt."
  value       = try(local.custom_prompt.test_question, null)
}
