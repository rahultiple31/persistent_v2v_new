mock_provider "aws" {}

mock_provider "aws" {
  alias = "us_east_1"
  mock_resource "aws_cloudformation_stack" {
    defaults = {
      outputs = {
        AssistantId     = "00000000-0000-0000-0000-000000000001"
        AgentVersionArn = "arn:aws:wisdom:us-east-1:123456789012:ai-agent/00000000-0000-0000-0000-000000000001/00000000-0000-0000-0000-000000000002:1"
      }
    }
  }
}

mock_provider "aws" {
  alias = "proxy_us_east_1"
}

mock_provider "external" {
  mock_data "external" {
    defaults = {
      result = {
        source_agent_id = "00000000-0000-0000-0000-000000000002"
        configuration   = "{\"Locale\":\"en_US\",\"ToolConfigurations\":[{\"ToolName\":\"Retrieve\",\"ToolType\":\"MODEL_CONTEXT_PROTOCOL\",\"ToolId\":\"copied-tool\"}]}"
        prompt_text     = "system: Voice protocol\nmessages:\n- '{{$.conversationHistory}}'\n"
      }
    }
  }
}

variables {
  cognito_domain_prefix        = "support-module-test"
  connect_instance_url         = "https://support-test.my.connect.aws"
  connect_instance_region      = "us-east-1"
  connect_admin_user_enabled   = false
  dev_ai_agent_enabled         = false
  dev_ai_domain_enabled        = true
  dev_ai_template_bucket       = "support-module-test-templates"
  dev_ai_prompt_model_id       = null
  dev_ai_tools                 = []
  dev_support_ai_agent_enabled = true
  dev_survey_ai_agent_enabled  = false
}

run "other_targets_exclude_support_module" {
  command = plan
  variables {
    enabled_modules             = []
    dev_survey_ai_agent_enabled = true
  }
  assert {
    condition     = length(module.btsgsd_support_agent) == 0 && output.btsgsd_support_agent == null && length(module.btsgsd_ai_survey_agent) == 0 && output.btsgsd_ai_survey_agent == null
    error_message = "Support and survey modules must be excluded outside the Connect target even when their flags are enabled."
  }
}

run "support_flag_controls_deployment" {
  command = plan
  variables {
    enabled_modules              = ["connect"]
    dev_support_ai_agent_enabled = false
  }
  assert {
    condition     = length(module.btsgsd_support_agent) == 0 && length(aws_cloudformation_stack.dev_ai_domain) == 1 && length(aws_s3_bucket.dev_ai_template) == 1
    error_message = "Disabling the support module must retain the separately enabled domain and bucket."
  }
}

run "support_does_not_enable_legacy_agent" {
  command = plan
  variables {
    enabled_modules = ["connect"]
  }
  assert {
    condition     = length(module.btsgsd_support_agent) == 1 && length(aws_cloudformation_stack.dev_ai_agent) == 0 && length(terraform_data.dev_ai_model_validation) == 0
    error_message = "Support deployment must work independently of the disabled legacy agent, model, and tool inputs."
  }
}

run "survey_is_independent_of_support_and_legacy" {
  command = plan
  variables {
    enabled_modules              = ["connect"]
    dev_support_ai_agent_enabled = false
    dev_survey_ai_agent_enabled  = true
  }
  assert {
    condition = (
      length(module.btsgsd_ai_survey_agent) == 1 &&
      length(module.btsgsd_support_agent) == 0 &&
      length(aws_cloudformation_stack.dev_ai_agent) == 0 &&
      length(aws_cloudformation_stack.dev_ai_domain) == 1 &&
      length(aws_s3_bucket.dev_ai_template) == 1
    )
    error_message = "Survey deployment must work independently while retaining its shared assistant and template bucket."
  }
}

run "survey_flag_controls_deployment" {
  command = plan
  variables {
    enabled_modules             = ["connect"]
    dev_survey_ai_agent_enabled = false
  }
  assert {
    condition     = length(module.btsgsd_ai_survey_agent) == 0 && output.btsgsd_ai_survey_agent == null && length(module.btsgsd_support_agent) == 1
    error_message = "Disabling survey must return a null survey output without disabling support."
  }
}
