output "deployment" {
  description = "Published prompt and agent identifiers, including the versioned ARN for voice routing."
  value       = aws_cloudformation_stack.agent.outputs
}

output "agent_version_arn" {
  value = aws_cloudformation_stack.agent.outputs["AgentVersionArn"]
}

output "test_question" {
  description = "Test metadata from the custom YAML, excluded from the model prompt."
  value       = try(local.custom_prompt.test_question, null)
}
