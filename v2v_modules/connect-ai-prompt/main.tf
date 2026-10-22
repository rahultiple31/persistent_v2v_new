locals {
  source_prompt = yamldecode(file(var.prompt_yaml_file))

  prompt_text = yamlencode({
    system = join("\n\n", compact([
      local.source_prompt.system,
      strcontains(local.source_prompt.system, "{{$.toolConfigurationList}}") ? "" : <<-TOOLS
        <toolConfigurationList>
        {{$.toolConfigurationList}}
        </toolConfigurationList>
      TOOLS
    ]))

    messages = local.source_prompt.messages
  })
}

resource "awscc_wisdom_ai_prompt" "survey" {
  assistant_id  = var.assistant_id
  name          = "BTSGSD-V2V-US-AI-Survey-Prompt"
  description   = "AbbVie Service Desk survey orchestration prompt."
  type          = "ORCHESTRATION"
  api_format    = "MESSAGES"
  template_type = "TEXT"

  # Amazon Connect model identifier for Claude 4.5 Haiku, Global.
  model_id = "global.anthropic.claude-haiku-4-5-20251001-v1:0"

  template_configuration = {
    text_full_ai_prompt_edit_template_configuration = {
      text = local.prompt_text
    }
  }

  tags = {
    Env = "SSO"
    Org = "BTSGSD"
  }
}

resource "awscc_wisdom_ai_prompt_version" "survey" {
  assistant_id          = var.assistant_id
  ai_prompt_id          = awscc_wisdom_ai_prompt.survey.ai_prompt_id
  modified_time_seconds = awscc_wisdom_ai_prompt.survey.modified_time_seconds
}
