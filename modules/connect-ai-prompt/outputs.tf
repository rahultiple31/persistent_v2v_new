output "prompt_id" {
  value = awscc_wisdom_ai_prompt.survey.ai_prompt_id
}

output "versioned_prompt_id" {
  value = format(
    "%s:%s",
    awscc_wisdom_ai_prompt.survey.ai_prompt_id,
    awscc_wisdom_ai_prompt_version.survey.version_number
  )
}
