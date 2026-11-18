output "deployment" {
  description = "Published prompt and agent identifiers, including the versioned ARN for voice routing."
  value = {
    AssistantId                = var.assistant_id
    AssistantArn               = awscc_wisdom_ai_agent.support.assistant_arn
    ConnectInstanceArn         = var.connect_instance_arn
    SourceAgentId              = data.external.source.result.source_agent_id
    AgentId                    = awscc_wisdom_ai_agent.support.ai_agent_id
    AgentArn                   = local.agent_arn
    AgentVersion               = local.agent_version_number
    AgentVersionId             = awscc_wisdom_ai_agent_version.support.ai_agent_version_id
    AgentVersionArn            = local.agent_version_arn
    PromptId                   = awscc_wisdom_ai_prompt.support.ai_prompt_id
    PromptVersion              = format("%d", awscc_wisdom_ai_prompt_version.support.version_number)
    KnowledgeBaseAssociationId = awscc_wisdom_assistant_association.knowledge_base.assistant_association_id
    KnowledgeBaseId            = var.knowledge_base_id
  }
}

output "agent_arn" {
  description = "Unqualified agent ARN."
  value       = local.agent_arn
}

output "agent_version_arn" {
  description = "Version-qualified agent ARN used by contact flows."
  value       = local.agent_version_arn
}

output "agent_version_number" {
  value = local.agent_version_number
}

output "assistant_arn" {
  value = awscc_wisdom_ai_agent.support.assistant_arn
}

output "test_question" {
  description = "Test metadata from the custom YAML, excluded from the model prompt."
  value       = try(local.custom_prompt.test_question, null)
}
