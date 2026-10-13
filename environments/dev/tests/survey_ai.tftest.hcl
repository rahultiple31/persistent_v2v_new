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
  cognito_domain_prefix                 = "survey-module-test"
  connect_instance_url                  = "https://survey-test.my.connect.aws"
  connect_instance_region               = "us-east-1"
  connect_admin_user_enabled            = false
  dev_ai_agent_enabled                  = false
  dev_ai_domain_enabled                 = true
  dev_ai_template_bucket                = "survey-module-test-templates"
  dev_ai_prompt_model_id                = null
  dev_ai_tools                          = []
  dev_survey_ai_agent_enabled           = true
  dev_support_ai_agent_enabled          = false
  dev_ai_admin_security_profile_enabled = true
}

run "other_targets_exclude_survey_module" {
  command = plan
  variables {
    enabled_modules              = []
    dev_support_ai_agent_enabled = true
  }
  assert {
    condition     = length(module.btsgsd_ai_survey_agent) == 0 && output.btsgsd_ai_survey_agent == null && length(module.btsgsd_support_agent) == 0 && output.btsgsd_support_agent == null && length(terraform_data.dev_ai_admin_security_profiles) == 0 && length(data.aws_connect_security_profile.ai_admin) == 0
    error_message = "The survey module must be excluded outside the Connect target even when its flag is enabled."
  }
}

run "survey_is_independent_of_legacy" {
  command = plan
  variables {
    enabled_modules = ["connect"]
  }
  assert {
    condition = (
      length(module.btsgsd_ai_survey_agent) == 1 &&
      length(aws_cloudformation_stack.dev_ai_agent) == 0 &&
      length(terraform_data.dev_ai_model_validation) == 0 &&
      length(aws_cloudformation_stack.dev_ai_domain) == 1 &&
      length(aws_s3_bucket.dev_ai_template) == 1
    )
    error_message = "Survey deployment must work independently of the legacy agent while retaining its shared assistant and template bucket."
  }
}

run "admin_assignment_works_without_a_human_admin_user" {
  command = plan
  variables {
    enabled_modules = ["connect"]
  }
  assert {
    condition = (
      length(data.aws_connect_security_profile.ai_admin) == 1 &&
      data.aws_connect_security_profile.ai_admin[0].name == "Admin" &&
      length(terraform_data.dev_ai_admin_security_profiles) == 1 &&
      terraform_data.dev_ai_admin_security_profiles[0].input.config.region == "us-east-1"
    )
    error_message = "Admin lookup and AI-agent assignments must be enabled independently of human admin-user creation."
  }
}

run "admin_assignment_flag_disables_migration" {
  command = plan
  variables {
    enabled_modules                       = ["connect"]
    dev_ai_admin_security_profile_enabled = false
  }
  assert {
    condition     = length(terraform_data.dev_ai_admin_security_profiles) == 0 && length(data.aws_connect_security_profile.ai_admin) == 0 && length(module.btsgsd_ai_survey_agent) == 1
    error_message = "Disabling Admin assignment must retain the survey agent without looking up or changing profiles."
  }
}

run "survey_flag_controls_deployment" {
  command = plan
  variables {
    enabled_modules             = ["connect"]
    dev_survey_ai_agent_enabled = false
  }
  assert {
    condition = (
      length(module.btsgsd_ai_survey_agent) == 0 &&
      output.btsgsd_ai_survey_agent == null &&
      length(aws_cloudformation_stack.dev_ai_domain) == 1 &&
      length(aws_s3_bucket.dev_ai_template) == 1
    )
    error_message = "Disabling survey must return a null survey output while retaining the separately enabled domain and bucket."
  }
}

run "support_deploys_independently_with_admin" {
  command = plan
  variables {
    enabled_modules              = ["connect"]
    dev_support_ai_agent_enabled = true
    dev_survey_ai_agent_enabled  = false
  }
  assert {
    condition = (
      length(module.btsgsd_support_agent) == 1 &&
      length(module.btsgsd_ai_survey_agent) == 0 &&
      length(aws_cloudformation_stack.dev_ai_agent) == 0 &&
      length(terraform_data.dev_ai_admin_security_profiles) == 1 &&
      length(data.aws_connect_security_profile.ai_admin) == 1
    )
    error_message = "The new SupportAgent must deploy independently with the required Admin assignment."
  }
}

run "support_requires_admin_assignment" {
  command = plan
  variables {
    enabled_modules                       = ["connect"]
    dev_support_ai_agent_enabled          = true
    dev_ai_admin_security_profile_enabled = false
  }
  expect_failures = [var.dev_support_ai_agent_enabled]
}
