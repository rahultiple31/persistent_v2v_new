# Deletes the module-owned CloudFormation stack, including:
# BTSGSD-V2V-US-ai-survey-agent
# BTSGSD-V2V-US-ai-survey-prompt
# Their versions and the module-owned S3 template object are also removed.
removed {
  from = module.btsgsd_ai_survey_agent

  lifecycle {
    destroy = true
  }
}
