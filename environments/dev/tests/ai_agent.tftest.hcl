mock_provider "aws" {}
mock_provider "aws" {
  alias = "us_east_1"
  mock_data "aws_region" {
    defaults = { name = "us-east-1" }
  }
}
mock_provider "aws" {
  alias = "proxy_us_east_1"
}

variables {
  enabled_modules        = ["connect"]
  connect_instance_alias = "btsgsd-dev-us-east-1"
  sso_enabled            = false
}

override_module {
  target = module.connect_us_east_1[0]
  outputs = {
    instance_id        = "11111111-1111-1111-1111-111111111111"
    instance_arn       = "arn:aws:connect:us-east-1:518902362956:instance/11111111-1111-1111-1111-111111111111"
    queue_id           = "22222222-2222-2222-2222-222222222222"
    routing_profile_id = "33333333-3333-3333-3333-333333333333"
    admin_user_id      = null
  }
}

run "disabled_without_ai_inputs" {
  command = plan

  assert {
    condition     = length(aws_cloudformation_stack.dev_ai_agent) == 0 && length(aws_s3_object.dev_ai_template) == 0 && output.dev_ai_agent == null
    error_message = "AI deployment must remain disabled without its required inputs."
  }
}

run "disabled_without_connect_or_prompt_file" {
  command = plan
  variables {
    enabled_modules    = []
    dev_ai_prompt_file = "metadata/prompts/not-present.yaml"
  }

  assert {
    condition     = local.dev_ai_template == null && length(aws_cloudformation_stack.dev_ai_agent) == 0
    error_message = "Disabled AI must not read its prompt or index a disabled Connect module."
  }
}

run "enabled_dev_agent_with_published_prompt" {
  command = plan
  variables {
    dev_ai_agent_enabled   = true
    dev_ai_assistant_id    = "160889f7-d564-47fb-97db-94549fc55993"
    dev_ai_prompt_model_id = "us.anthropic.claude-3-7-sonnet-20250219-v1:0"
    dev_ai_template_bucket = "dev-ai-template-test"
    dev_ai_tools = [
      { ToolName = "GenerateNotes", ToolType = "MODEL_CONTEXT_PROTOCOL", ToolId = "test-generate-notes" },
      { ToolName = "Retrieve", ToolType = "MODEL_CONTEXT_PROTOCOL", ToolId = "test-retrieve" }
    ]
  }

  assert {
    condition     = length(aws_cloudformation_stack.dev_ai_agent) == 1 && length(aws_s3_object.dev_ai_template) == 1
    error_message = "Enabled Dev AI must provision its S3-hosted CloudFormation stack."
  }
  assert {
    condition     = jsondecode(local.dev_ai_template).Resources.DevAIAgent.Properties.Configuration.OrchestrationAIAgentConfiguration.ConnectInstanceArn == "arn:aws:connect:us-east-1:518902362956:instance/11111111-1111-1111-1111-111111111111"
    error_message = "The AI agent must target the Dev Connect module output."
  }
  assert {
    condition     = yamldecode(jsondecode(local.dev_ai_template).Resources.DevPrompt.Properties.TemplateConfiguration.TextFullAIPromptEditTemplateConfiguration.Text).messages[0] == "{{$.conversationHistory}}"
    error_message = "The complete prompt must remain valid YAML and preserve its runtime conversation history."
  }
  assert {
    condition     = jsondecode(local.dev_ai_template).Resources.DevAIAgent.Properties.Configuration.OrchestrationAIAgentConfiguration.OrchestrationAIPromptId["Fn::Join"][1][1]["Fn::GetAtt"] == ["DevPromptVersion", "VersionNumber"]
    error_message = "The agent must reference a published prompt version."
  }
  assert {
    condition     = jsondecode(local.dev_ai_template).Resources.DevAIAgentVersion.Properties.ModifiedTimeSeconds["Fn::GetAtt"] == ["DevAIAgent", "ModifiedTimeSeconds"]
    error_message = "Updating the agent must trigger publication of a new version."
  }
}

run "reject_ai_without_connect" {
  command = plan
  variables {
    enabled_modules      = []
    dev_ai_agent_enabled = true
    dev_ai_assistant_id  = "160889f7-d564-47fb-97db-94549fc55993"
  }
  expect_failures = [
    var.dev_ai_agent_enabled
  ]
}

run "reject_missing_model" {
  command = plan
  variables {
    dev_ai_agent_enabled   = true
    dev_ai_assistant_id    = "160889f7-d564-47fb-97db-94549fc55993"
    dev_ai_prompt_model_id = ""
    dev_ai_template_bucket = "dev-ai-template-test"
    dev_ai_tools           = [{ ToolName = "Retrieve", ToolType = "MODEL_CONTEXT_PROTOCOL", ToolId = "test-retrieve" }]
  }
  expect_failures = [var.dev_ai_prompt_model_id]
}
