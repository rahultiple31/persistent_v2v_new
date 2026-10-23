mock_provider "aws" {
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::518902362956:role/mock-lex-role" }
  }
  mock_resource "aws_lexv2models_bot" {
    defaults = { id = "QT2GQYM5TT" }
  }
  mock_resource "aws_lexv2models_bot_version" {
    defaults = { bot_version = "2" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1", name = "us-east-1" }
  }
}

mock_provider "awscc" {
  mock_resource "awscc_lex_bot_alias" {
    defaults = {
      arn          = "arn:aws:lex:us-east-1:518902362956:bot-alias/QT2GQYM5TT/6NLNDQWUJ8"
      bot_alias_id = "6NLNDQWUJ8"
    }
  }
}


# Requires Terraform >= 1.11 for plan-time computed-value overrides.
# Keep tests at plan time: the module's AWS CLI provisioners must never run.
override_resource {
  override_during = plan
  target          = awscc_lex_bot_alias.this[0]
  values = {
    arn          = "arn:aws:lex:us-east-1:518902362956:bot-alias/QT2GQYM5TT/6NLNDQWUJ8"
    bot_alias_id = "6NLNDQWUJ8"
  }
}
override_resource {
  override_during = plan
  target          = aws_lexv2models_bot_version.alias_text_logs[0]
  values          = { bot_version = "2" }
}

variables {
  bot_name                        = "BTSGSD-V2V-US-yesNo"
  locale_ids                      = ["en_US", "es_419", "pt_BR"]
  child_directed                  = false
  enable_english_yesno_intents    = true
  enable_portuguese_yesno_intents = true
  enable_spanish_yesno_intents    = true
  publish_yesno_version           = true

  alias_configuration = {
    name                 = "BTSGSD-V2V-US-DEV"
    connect_instance_arn = "arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d"
    lambda_function_arn  = "arn:aws:lambda:us-east-1:518902362956:function:BTSGSD-V2V-US-lex-yesNo"
    text_log_group_arn   = "arn:aws:logs:us-east-1:518902362956:log-group:/aws/lex/BTSGSD-V2V-US-yesNo"
  }
}

run "alias_languages_and_connect_policy" {
  command = plan

  assert {
    condition = (
      awscc_lex_bot_alias.this[0].bot_alias_name == "BTSGSD-V2V-US-DEV" &&
      awscc_lex_bot_alias.this[0].bot_version == aws_lexv2models_bot_version.alias_text_logs[0].bot_version &&
      toset([for item in awscc_lex_bot_alias.this[0].bot_alias_locale_settings : item.locale_id]) == toset(["en_US", "es_419", "pt_BR"]) &&
      alltrue([for item in awscc_lex_bot_alias.this[0].bot_alias_locale_settings : item.bot_alias_locale_setting.enabled])
    )
    error_message = "Alias must use the published version and enable the requested languages."
  }

  assert {
    condition = alltrue([
      for item in awscc_lex_bot_alias.this[0].bot_alias_locale_settings :
      item.bot_alias_locale_setting.code_hook_specification.lambda_code_hook.lambda_arn == var.alias_configuration.lambda_function_arn &&
      item.bot_alias_locale_setting.code_hook_specification.lambda_code_hook.code_hook_interface_version == "1.0"
    ])
    error_message = "All three locales must invoke the requested Lambda at $LATEST."
  }

  assert {
    condition = (
      aws_lambda_permission.lex_alias[0].function_name == var.alias_configuration.lambda_function_arn &&
      aws_lambda_permission.lex_alias[0].source_arn == awscc_lex_bot_alias.this[0].arn &&
      aws_lambda_permission.lex_alias[0].source_account == "518902362956" &&
      aws_lambda_permission.lex_alias[0].action == "lambda:InvokeFunction" &&
      aws_lambda_permission.lex_alias[0].principal == "lexv2.amazonaws.com" &&
      aws_lambda_permission.lex_alias[0].qualifier == null
    )
    error_message = "Invocation permission must target the unqualified function and be scoped to this Lex alias."
  }

  assert {
    condition = (
      length(awscc_lex_bot_alias.this[0].conversation_log_settings.text_log_settings) == 1 &&
      one(awscc_lex_bot_alias.this[0].conversation_log_settings.text_log_settings).enabled &&
      one(awscc_lex_bot_alias.this[0].conversation_log_settings.text_log_settings).destination.cloudwatch.cloudwatch_log_group_arn == var.alias_configuration.text_log_group_arn &&
      one(awscc_lex_bot_alias.this[0].conversation_log_settings.text_log_settings).destination.cloudwatch.log_prefix == var.alias_configuration.name &&
      length(awscc_lex_bot_alias.this[0].conversation_log_settings.audio_log_settings) == 0
    )
    error_message = "Text logs must use the requested log group and alias prefix; audio logs remain disabled."
  }

  assert {
    condition = (
      jsondecode(awscc_lex_resource_policy.connect[0].policy).Statement[0].Resource == awscc_lex_bot_alias.this[0].arn &&
      jsondecode(awscc_lex_resource_policy.connect[0].policy).Statement[0].Sid == "connect-us-east-1-c227a737-3e4f-4c64-8397-2d37e318801d" &&
      jsondecode(awscc_lex_resource_policy.connect[0].policy).Statement[0].Principal.Service == "connect.amazonaws.com" &&
      jsondecode(awscc_lex_resource_policy.connect[0].policy).Statement[0].Condition.StringEquals["AWS:SourceAccount"] == "518902362956" &&
      jsondecode(awscc_lex_resource_policy.connect[0].policy).Statement[0].Condition.ArnEquals["AWS:SourceArn"] == var.alias_configuration.connect_instance_arn &&
      toset(jsondecode(awscc_lex_resource_policy.connect[0].policy).Statement[0].Action) == toset([
        "lex:RecognizeText", "lex:StartConversation", "lex:RecognizeMessageAsync",
      ])
    )
    error_message = "Policy must scope the requested actions to the supplied Connect source and managed alias."
  }
}

run "policy_follows_the_selected_connect_instance" {
  command = plan

  variables {
    alias_configuration = merge(var.alias_configuration, {
      connect_instance_arn = "arn:aws:connect:us-east-1:123456789012:instance/11111111-2222-3333-4444-555555555555"
    })
  }

  assert {
    condition = (
      jsondecode(awscc_lex_resource_policy.connect[0].policy).Statement[0].Condition.StringEquals["AWS:SourceAccount"] == "123456789012" &&
      jsondecode(awscc_lex_resource_policy.connect[0].policy).Statement[0].Condition.ArnEquals["AWS:SourceArn"] == var.alias_configuration.connect_instance_arn &&
      jsondecode(awscc_lex_resource_policy.connect[0].policy).Statement[0].Resource == awscc_lex_bot_alias.this[0].arn
    )
    error_message = "The policy must derive its source restrictions from the selected instance."
  }
}

run "alias_requires_publishing" {
  command = plan

  variables {
    publish_yesno_version = false
  }

  expect_failures = [var.alias_configuration]
}

run "log_group_wildcard_is_removed_from_destination" {
  command = plan

  variables {
    alias_configuration = merge(var.alias_configuration, {
      text_log_group_arn = "arn:aws:logs:us-east-1:518902362956:log-group:/aws/lex/BTSGSD-V2V-US-yesNo:*"
    })
  }

  assert {
    condition = (
      one(awscc_lex_bot_alias.this[0].conversation_log_settings.text_log_settings).destination.cloudwatch.cloudwatch_log_group_arn ==
      trimsuffix(var.alias_configuration.text_log_group_arn, ":*")
    )
    error_message = "The log destination must use the group ARN without the IAM stream wildcard."
  }
}

run "lambda_function_must_be_unqualified" {
  command = plan

  variables {
    alias_configuration = merge(var.alias_configuration, {
      lambda_function_arn = "arn:aws:lambda:us-east-1:518902362956:function:BTSGSD-V2V-US-lex-yesNo:1"
    })
  }

  expect_failures = [var.alias_configuration]
}

run "latest_uses_the_unqualified_function" {
  command = plan

  variables {
    alias_configuration = merge(var.alias_configuration, {
      lambda_function_arn = "arn:aws:lambda:us-east-1:518902362956:function:BTSGSD-V2V-US-lex-yesNo:$LATEST"
    })
  }

  expect_failures = [var.alias_configuration]
}

run "text_logs_require_coppa_false" {
  command = plan
  variables { child_directed = true }
  expect_failures = [var.alias_configuration]
}

run "logging_permissions_and_version_are_scoped" {
  command = plan
  assert {
    condition = (
      jsondecode(aws_iam_role_policy.alias_text_logs[0].policy).Statement[0].Resource == "${var.alias_configuration.text_log_group_arn}:*" &&
      toset(jsondecode(aws_iam_role_policy.alias_text_logs[0].policy).Statement[0].Action) == toset(["logs:CreateLogStream", "logs:PutLogEvents"]) &&
      aws_iam_role_policy.alias_text_logs[0].role == aws_iam_role.lex.name
    )
    error_message = "Log permissions must allow writes only to streams in the configured group."
  }
  assert {
    condition = (
      toset(keys(aws_lexv2models_bot_version.alias_text_logs[0].locale_specification)) == toset(["en_US", "pt_BR", "es_419"]) &&
      alltrue([for item in values(aws_lexv2models_bot_version.alias_text_logs[0].locale_specification) : item.source_bot_version == "DRAFT"])
    )
    error_message = "The logging snapshot must publish all three DRAFT locales."
  }
}

run "customer_queue_alias_logs_and_connect_policy" {
  command = plan

  variables {
    bot_name                                 = "BTSGSD-V2V-US-customerQueueFlowBot"
    enable_english_yesno_intents             = false
    enable_portuguese_yesno_intents          = false
    enable_spanish_yesno_intents             = false
    publish_yesno_version                    = false
    enable_english_customer_queue_intents    = true
    enable_portuguese_customer_queue_intents = true
    enable_spanish_customer_queue_intents    = true
    publish_customer_queue_version           = true

    alias_configuration = {
      name                 = "BTSGSD-V2V-US-DEV"
      lambda_function_arn  = "arn:aws:lambda:us-east-1:518902362956:function:BTSGSD-V2V-US-conversionOfQueueMetrics"
      connect_instance_arn = "arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d"
      text_log_group_arn   = "arn:aws:logs:us-east-1:518902362956:log-group:/aws/lex/BTSGSD-V2V-US-customerQueueFlowBot"
    }
  }

  override_resource {
    target          = aws_lexv2models_bot.this
    override_during = plan
    values          = { id = "RD35A35EAU" }
  }

  override_resource {
    target          = awscc_lex_bot_alias.this[0]
    override_during = plan
    values = {
      arn          = "arn:aws:lex:us-east-1:518902362956:bot-alias/RD35A35EAU/HJAVDZTZBO"
      bot_alias_id = "HJAVDZTZBO"
    }
  }

  assert {
    condition = (
      !aws_lexv2models_bot.this.data_privacy[0].child_directed &&
      length(terraform_data.customer_queue_locale_build) == 1 &&
      !terraform_data.customer_queue_locale_build[0].triggers_replace.child_directed &&
      length(terraform_data.yesno_locale_build) == 0 &&
      length(aws_lexv2models_bot_version.yesno_version_1) == 0 &&
      awscc_lex_bot_alias.this[0].bot_id == "RD35A35EAU" &&
      awscc_lex_bot_alias.this[0].bot_alias_name == "BTSGSD-V2V-US-DEV" &&
      awscc_lex_bot_alias.this[0].bot_version == aws_lexv2models_bot_version.alias_text_logs[0].bot_version &&
      toset(keys(aws_lexv2models_bot_version.alias_text_logs[0].locale_specification)) == toset(["en_US", "pt_BR", "es_419"]) &&
      alltrue([for item in values(aws_lexv2models_bot_version.alias_text_logs[0].locale_specification) : item.source_bot_version == "DRAFT"]) &&
      toset([for item in awscc_lex_bot_alias.this[0].bot_alias_locale_settings : item.locale_id]) == toset(["en_US", "pt_BR", "es_419"]) &&
      alltrue([
        for item in awscc_lex_bot_alias.this[0].bot_alias_locale_settings :
        item.bot_alias_locale_setting.enabled &&
        item.bot_alias_locale_setting.code_hook_specification.lambda_code_hook.lambda_arn == var.alias_configuration.lambda_function_arn
      ])
    )
    error_message = "The customer queue alias must use COPPA=false, its own locale build, the published three-language snapshot and the queue metrics Lambda."
  }

  assert {
    condition = (
      one(awscc_lex_bot_alias.this[0].conversation_log_settings.text_log_settings).enabled &&
      one(awscc_lex_bot_alias.this[0].conversation_log_settings.text_log_settings).destination.cloudwatch.cloudwatch_log_group_arn == var.alias_configuration.text_log_group_arn &&
      one(awscc_lex_bot_alias.this[0].conversation_log_settings.text_log_settings).destination.cloudwatch.log_prefix == var.alias_configuration.name &&
      length(awscc_lex_bot_alias.this[0].conversation_log_settings.audio_log_settings) == 0 &&
      jsondecode(aws_iam_role_policy.alias_text_logs[0].policy).Statement[0].Resource == "${var.alias_configuration.text_log_group_arn}:*" &&
      toset(jsondecode(aws_iam_role_policy.alias_text_logs[0].policy).Statement[0].Action) == toset(["logs:CreateLogStream", "logs:PutLogEvents"]) &&
      aws_lambda_permission.lex_alias[0].function_name == var.alias_configuration.lambda_function_arn &&
      aws_lambda_permission.lex_alias[0].source_arn == awscc_lex_bot_alias.this[0].arn &&
      aws_lambda_permission.lex_alias[0].source_account == "518902362956" &&
      aws_lambda_permission.lex_alias[0].principal == "lexv2.amazonaws.com" &&
      aws_lambda_permission.lex_alias[0].qualifier == null
    )
    error_message = "Customer queue text logs and Lambda invocation permissions must be scoped to the configured log group and alias."
  }

  assert {
    condition = (
      awscc_lex_resource_policy.connect[0].resource_arn == awscc_lex_bot_alias.this[0].arn &&
      jsondecode(awscc_lex_resource_policy.connect[0].policy).Statement[0].Resource == "arn:aws:lex:us-east-1:518902362956:bot-alias/RD35A35EAU/HJAVDZTZBO" &&
      jsondecode(awscc_lex_resource_policy.connect[0].policy).Statement[0].Sid == "connect-us-east-1-c227a737-3e4f-4c64-8397-2d37e318801d" &&
      jsondecode(awscc_lex_resource_policy.connect[0].policy).Statement[0].Principal.Service == "connect.amazonaws.com" &&
      jsondecode(awscc_lex_resource_policy.connect[0].policy).Statement[0].Condition.StringEquals["AWS:SourceAccount"] == "518902362956" &&
      jsondecode(awscc_lex_resource_policy.connect[0].policy).Statement[0].Condition.ArnEquals["AWS:SourceArn"] == var.alias_configuration.connect_instance_arn &&
      toset(jsondecode(awscc_lex_resource_policy.connect[0].policy).Statement[0].Action) == toset(["lex:RecognizeText", "lex:StartConversation", "lex:RecognizeMessageAsync"])
    )
    error_message = "The customer queue alias must generate the supplied Connect resource policy using its actual alias ARN."
  }
}

run "customer_queue_text_logs_require_coppa_false" {
  command = plan
  variables {
    enable_english_yesno_intents             = false
    enable_portuguese_yesno_intents          = false
    enable_spanish_yesno_intents             = false
    publish_yesno_version                    = false
    enable_english_customer_queue_intents    = true
    enable_portuguese_customer_queue_intents = true
    enable_spanish_customer_queue_intents    = true
    publish_customer_queue_version           = true
    child_directed                           = true
  }
  expect_failures = [var.alias_configuration]
}
