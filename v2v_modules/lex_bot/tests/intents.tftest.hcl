mock_provider "aws" {
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock-lex-role"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "us-east-1"
      name   = "us-east-1"
    }
  }
}

mock_provider "awscc" {}

variables {
  bot_name   = "BTSGSD-V2V-US-yesNo"
  locale_ids = ["en_US", "pt_BR", "es_419"]
}

run "other_bots_remain_blank_by_default" {
  command = plan

  variables {
    bot_name = "BTSGSD-V2V-US-customerQueueFlowBot"
  }

  assert {
    condition = (
      length(aws_lexv2models_intent.english_yesno) == 0 &&
      length(aws_lexv2models_intent.portuguese_yesno) == 0 &&
      length(aws_lexv2models_intent.spanish_yesno) == 0 &&
      length(terraform_data.english_fallback) == 0 &&
      length(terraform_data.portuguese_fallback) == 0 &&
      length(terraform_data.spanish_fallback) == 0 &&
      length(terraform_data.yesno_locale_build) == 0 &&
      length(aws_lexv2models_bot_version.yesno_version_1) == 0 &&
      length(awscc_lex_bot_alias.this) == 0 &&
      length(aws_lambda_permission.lex_alias) == 0 &&
      length(awscc_lex_resource_policy.connect) == 0 &&
      length(aws_iam_role_policy.alias_text_logs) == 0 &&
      length(aws_lexv2models_bot_version.alias_text_logs) == 0
    )
    error_message = "Existing callers must not receive survey intents unless enabled."
  }
}

run "all_three_locales_receive_survey_intents" {
  command = plan

  variables {
    enable_english_yesno_intents    = true
    enable_portuguese_yesno_intents = true
    enable_spanish_yesno_intents    = true
  }

  assert {
    condition = alltrue([
      for intents in [
        aws_lexv2models_intent.english_yesno,
        aws_lexv2models_intent.portuguese_yesno,
        aws_lexv2models_intent.spanish_yesno,
      ] : toset(keys(intents)) == toset(["repeat", "yes", "dtmf", "no"])
    ])
    error_message = "Each language must receive the four requested custom intents."
  }

  assert {
    condition = alltrue(concat(
      [for intent in values(aws_lexv2models_intent.english_yesno) : intent.locale_id == "en_US"],
      [for intent in values(aws_lexv2models_intent.portuguese_yesno) : intent.locale_id == "pt_BR"],
      [for intent in values(aws_lexv2models_intent.spanish_yesno) : intent.locale_id == "es_419"],
    ))
    error_message = "An intent must belong to its requested locale."
  }

  assert {
    condition = alltrue([
      for intent in concat(
        values(aws_lexv2models_intent.english_yesno),
        values(aws_lexv2models_intent.portuguese_yesno),
        values(aws_lexv2models_intent.spanish_yesno),
      ) : intent.dialog_code_hook[0].enabled && intent.fulfillment_code_hook[0].active
    ])
    error_message = "Initialization/validation and the fulfillment stage must be enabled."
  }

  assert {
    condition = (
      sum([for intent in values(aws_lexv2models_intent.english_yesno) : length(intent.sample_utterance)]) == 47 &&
      sum([for intent in values(aws_lexv2models_intent.portuguese_yesno) : length(intent.sample_utterance)]) == 86 &&
      sum([for intent in values(aws_lexv2models_intent.spanish_yesno) : length(intent.sample_utterance)]) == 41
    )
    error_message = "All supplied utterances must be preserved in their language."
  }

  assert {
    condition = (
      contains([for sample in aws_lexv2models_intent.spanish_yesno["yes"].sample_utterance : sample.utterance], "sí") &&
      contains([for sample in aws_lexv2models_intent.spanish_yesno["yes"].sample_utterance : sample.utterance], "sí, ¿por qué no?") &&
      contains([for sample in aws_lexv2models_intent.spanish_yesno["repeat"].sample_utterance : sample.utterance], "¿podrías repetir?") &&
      contains([for sample in aws_lexv2models_intent.spanish_yesno["repeat"].sample_utterance : sample.utterance], "no escuché eso") &&
      contains([for sample in aws_lexv2models_intent.portuguese_yesno["no"].sample_utterance : sample.utterance], "não") &&
      contains([for sample in aws_lexv2models_intent.portuguese_yesno["repeat"].sample_utterance : sample.utterance], "você pode repetir isso?") &&
      contains([for sample in aws_lexv2models_intent.portuguese_yesno["repeat"].sample_utterance : sample.utterance], "repete aí") &&
      contains([for sample in aws_lexv2models_intent.portuguese_yesno["yes"].sample_utterance : sample.utterance], "foi ótimo")
    )
    error_message = "Accents and inverted question marks must survive UTF-8 file encoding."
  }

  assert {
    condition = (
      length(terraform_data.english_fallback) == 1 &&
      length(terraform_data.portuguese_fallback) == 1 &&
      length(terraform_data.spanish_fallback) == 1
    )
    error_message = "Each enabled locale must configure its existing fallback intent."
  }
}

run "portuguese_can_be_enabled_independently" {
  command = plan

  variables {
    locale_ids                      = ["pt_BR"]
    enable_portuguese_yesno_intents = true
  }

  assert {
    condition = (
      length(aws_lexv2models_intent.portuguese_yesno) == 4 &&
      length(aws_lexv2models_intent.english_yesno) == 0 &&
      length(aws_lexv2models_intent.spanish_yesno) == 0
    )
    error_message = "Portuguese configuration must not require other locales."
  }
}

run "spanish_can_be_enabled_independently" {
  command = plan

  variables {
    locale_ids                   = ["es_419"]
    enable_spanish_yesno_intents = true
  }

  assert {
    condition = (
      length(aws_lexv2models_intent.spanish_yesno) == 4 &&
      length(aws_lexv2models_intent.english_yesno) == 0 &&
      length(aws_lexv2models_intent.portuguese_yesno) == 0
    )
    error_message = "Spanish configuration must not require other locales."
  }
}

run "english_requires_its_locale" {
  command = plan

  variables {
    locale_ids                   = ["pt_BR"]
    enable_english_yesno_intents = true
  }

  expect_failures = [var.enable_english_yesno_intents]
}

run "portuguese_requires_its_locale" {
  command = plan

  variables {
    locale_ids                      = ["en_US"]
    enable_portuguese_yesno_intents = true
  }

  expect_failures = [var.enable_portuguese_yesno_intents]
}

run "spanish_requires_its_locale" {
  command = plan

  variables {
    locale_ids                   = ["en_US"]
    enable_spanish_yesno_intents = true
  }

  expect_failures = [var.enable_spanish_yesno_intents]
}

run "publish_one_snapshot_with_three_locales" {
  command = plan

  variables {
    enable_english_yesno_intents    = true
    enable_portuguese_yesno_intents = true
    enable_spanish_yesno_intents    = true
    publish_yesno_version           = true
    child_directed                  = false
  }

  assert {
    condition = (
      length(terraform_data.yesno_locale_build) == 1 &&
      terraform_data.yesno_locale_build[0].triggers_replace.child_directed == false &&
      length(aws_lexv2models_bot_version.yesno_version_1) == 1
    )
    error_message = "Publication must build the locales and create one bot version."
  }

  assert {
    condition = (
      toset(keys(aws_lexv2models_bot_version.yesno_version_1[0].locale_specification)) == toset(["en_US", "pt_BR", "es_419"]) &&
      alltrue([
        for locale in values(aws_lexv2models_bot_version.yesno_version_1[0].locale_specification) :
        locale.source_bot_version == "DRAFT"
      ])
    )
    error_message = "The published snapshot must include all three DRAFT locales."
  }
}

run "publication_requires_all_intent_flags" {
  command = plan

  variables {
    publish_yesno_version = true
  }

  expect_failures = [var.publish_yesno_version]
}
