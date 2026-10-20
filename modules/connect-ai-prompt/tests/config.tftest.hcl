mock_provider "awscc" {
  mock_resource "awscc_wisdom_ai_prompt" {
    defaults = {
      ai_prompt_id          = "22222222-2222-2222-2222-222222222222"
      modified_time_seconds = 1700000000
    }
  }

  mock_resource "awscc_wisdom_ai_prompt_version" {
    defaults = {
      version_number = 3
    }
  }
}

variables {
  assistant_id     = "11111111-1111-1111-1111-111111111111"
  prompt_yaml_file = "../../environments/dev/metadata/prompts/BTSGSD-SSO-US-AI-Survey-Prompt.yaml"
}

run "survey_prompt_is_published" {
  command = apply

  assert {
    condition = (
      awscc_wisdom_ai_prompt.survey.name == "BTSGSD-SSO-US-AI-Survey-Prompt" &&
      awscc_wisdom_ai_prompt.survey.type == "ORCHESTRATION" &&
      awscc_wisdom_ai_prompt.survey.api_format == "MESSAGES" &&
      awscc_wisdom_ai_prompt.survey.model_id == "global.anthropic.claude-haiku-4-5-20251001-v1:0" &&
      awscc_wisdom_ai_prompt.survey.assistant_id == var.assistant_id
    )
    error_message = "Publish the survey orchestration prompt using the requested global Haiku model and existing assistant."
  }

  assert {
    condition = (
      startswith(yamldecode(local.prompt_text).system, local.source_prompt.system) &&
      strcontains(yamldecode(local.prompt_text).system, "{{$.toolConfigurationList}}") &&
      yamldecode(local.prompt_text).messages == local.source_prompt.messages &&
      strcontains(yamldecode(local.prompt_text).system, "{{$.Custom.language_name}}") &&
      strcontains(yamldecode(local.prompt_text).system, "{{$.Custom.agentC}}") &&
      yamldecode(local.prompt_text).messages[0] == "{{$.conversationHistory}}"
    )
    error_message = "Preserve the complete supplied policy, runtime variables and conversation history while exposing the agent's tools."
  }

  assert {
    condition = (
      output.versioned_prompt_id == "22222222-2222-2222-2222-222222222222:3" &&
      awscc_wisdom_ai_prompt_version.survey.modified_time_seconds == awscc_wisdom_ai_prompt.survey.modified_time_seconds
    )
    error_message = "Attach a published UUID:version prompt identifier and republish when the prompt changes."
  }
}
