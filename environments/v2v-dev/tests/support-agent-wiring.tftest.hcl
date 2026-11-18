mock_provider "aws" {}
mock_provider "aws" {
  alias = "us_east_1"
  mock_data "aws_connect_instance" {
    defaults = {
      id  = "bcc989e5-cd9d-494f-9cd4-434f39ccc90e"
      arn = "arn:aws:connect:us-east-1:518902362956:instance/bcc989e5-cd9d-494f-9cd4-434f39ccc90e"
    }
  }
  mock_data "aws_cloudformation_stack" {
    defaults = {
      outputs = {
        AssistantId  = "e36d6b86-c3f5-4d6d-b85b-e44f7e7ec04f"
        AssistantArn = "arn:aws:wisdom:us-east-1:518902362956:assistant/e36d6b86-c3f5-4d6d-b85b-e44f7e7ec04f"
      }
    }
  }
}
mock_provider "awscc" {
  alias = "us_east_1"
}
mock_provider "archive" {}
# Data sources are read during plan, so this default is known at plan time
# (no override_during, which the pipeline's Terraform 1.10 does not support).
mock_provider "external" {
  mock_data "external" {
    defaults = {
      result = {
        alias_arn = "arn:aws:lex:us-east-1:518902362956:bot-alias/ITSUPPORT1/ALIAS12345"
      }
    }
  }
}

variables {
  environment             = "v2v"
  translation_enabled     = false
  cognito_domain_prefix   = "support-agent-wiring-test"
  connect_instance_url    = "https://btsgsd-dev-v2v-poc-us-east-1.my.connect.aws"
  connect_instance_region = "us-east-1"
  connect_instance_alias  = "btsgsd-dev-v2v-poc-us-east-1"
}

# The Main IB flow's IT Support alias is looked up by the bot and alias names
# module.lex_bot uses, in the V2V account.
run "connect_state_looks_up_the_v2v_it_support_alias" {
  command = plan
  variables {
    enabled_modules = ["connect"]
  }
  plan_options {
    target = [data.external.it_support_bot_alias, data.aws_cloudformation_stack.v2v_ai_domain]
  }
  assert {
    condition = (
      data.external.it_support_bot_alias[0].query.bot_name == "BTSGSD-V2V-US-IT-Support_Agent" &&
      data.external.it_support_bot_alias[0].query.alias_name == "btsgsd-alias-dev-sso" &&
      data.external.it_support_bot_alias[0].query.account_id == "518902362956"
    )
    error_message = "The alias lookup must use module.lex_bot's names in the V2V account."
  }
  assert {
    condition     = output.v2v_ai_wiring.it_support_bot_alias_arn == "arn:aws:lex:us-east-1:518902362956:bot-alias/ITSUPPORT1/ALIAS12345"
    error_message = "The Main IB flow must receive the looked-up V2V IT Support alias."
  }
  assert {
    condition     = length(data.aws_cloudformation_stack.v2v_ai_domain) == 0
    error_message = "The connect state owns the AI domain stack and must not read it as data."
  }
}

run "connect_state_alias_override_skips_the_lookup" {
  command = plan
  variables {
    enabled_modules                  = ["connect"]
    main_ib_it_support_bot_alias_arn = "arn:aws:lex:us-east-1:518902362956:bot-alias/ITSUPPORT1/OVERRIDE01"
  }
  plan_options {
    target = [data.external.it_support_bot_alias]
  }
  assert {
    condition     = length(data.external.it_support_bot_alias) == 0
    error_message = "An explicit alias ARN must replace the lookup."
  }
}

run "knowledge_base_is_required_with_the_support_agent" {
  command = plan
  variables {
    enabled_modules                       = ["connect"]
    dev_support_ai_agent_enabled          = true
    dev_ai_admin_security_profile_enabled = true
    dev_support_ai_knowledge_base_id      = "btsgsd-knowledgebase"
  }
  plan_options {
    target = [module.btsgsd_support_agent]
  }
  expect_failures = [var.dev_support_ai_knowledge_base_id]
}

# States outside connect resolve the V2V assistant and instance instead of
# the dev ones that were hard-coded before.
run "lex_bot_state_uses_the_v2v_assistant_and_instance" {
  command = plan
  variables {
    enabled_modules = ["lex_bot"]
  }
  plan_options {
    target = [data.aws_cloudformation_stack.v2v_ai_domain, data.aws_connect_instance.target, data.external.it_support_bot_alias]
  }
  assert {
    condition     = data.aws_cloudformation_stack.v2v_ai_domain[0].name == "BTSGSD-V2V-US-ai-domain"
    error_message = "The assistant must come from the V2V AI domain stack."
  }
  assert {
    condition = (
      output.v2v_ai_wiring.assistant_arn == "arn:aws:wisdom:us-east-1:518902362956:assistant/e36d6b86-c3f5-4d6d-b85b-e44f7e7ec04f" &&
      output.v2v_ai_wiring.connect_instance_arn == "arn:aws:connect:us-east-1:518902362956:instance/bcc989e5-cd9d-494f-9cd4-434f39ccc90e"
    )
    error_message = "The IT Support bot must be configured with the V2V assistant and instance."
  }
}

run "snow_states_allow_the_v2v_assistant_agents" {
  command = plan
  variables {
    enabled_modules = ["btsgsd-v2v-us-servicenow_interaction"]
  }
  plan_options {
    target = [data.aws_cloudformation_stack.v2v_ai_domain, data.aws_connect_instance.target, data.external.it_support_bot_alias]
  }
  assert {
    condition     = output.v2v_ai_wiring.ai_agent_source_arn == "arn:aws:wisdom:us-east-1:518902362956:ai-agent/e36d6b86-c3f5-4d6d-b85b-e44f7e7ec04f/*"
    error_message = "AgentCore invoke permissions must cover every agent on the V2V assistant."
  }
}

run "other_states_do_not_read_ai_dependencies" {
  command = plan
  variables {
    enabled_modules = ["monitoring"]
  }
  plan_options {
    target = [data.aws_cloudformation_stack.v2v_ai_domain, data.aws_connect_instance.target, data.external.it_support_bot_alias]
  }
  assert {
    condition = (
      length(data.aws_cloudformation_stack.v2v_ai_domain) == 0 &&
      length(data.aws_connect_instance.target) == 0 &&
      length(data.external.it_support_bot_alias) == 0
    )
    error_message = "Only the states that use the V2V AI wiring may read it."
  }
}
