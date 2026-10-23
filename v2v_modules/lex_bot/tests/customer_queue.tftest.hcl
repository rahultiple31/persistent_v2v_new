mock_provider "aws" {
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::518902362956:role/mock-customer-queue-role" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1", name = "us-east-1" }
  }
}

mock_provider "awscc" {}

# Terraform >= 1.11 is needed for this plan-time computed-value override.
# All tests use plan, so the fallback AWS CLI provisioner never executes.
override_resource {
  target          = aws_lexv2models_bot.this
  override_during = plan
  values          = { id = "QT2GQYM5TT" }
}

variables {
  bot_name                              = "BTSGSD-V2V-US-customerQueueFlowBot"
  locale_ids                            = ["en_US", "pt_BR", "es_419"]
  child_directed                        = true
  enable_english_customer_queue_intents = true
}

run "english_customer_queue_intents" {
  command = plan

  assert {
    condition = (
      aws_lexv2models_bot.this.data_privacy[0].child_directed &&
      toset(keys(aws_lexv2models_intent.english_customer_queue)) == toset(["repeat", "virtualQueue", "voicemail"]) &&
      alltrue([
        for intent in values(aws_lexv2models_intent.english_customer_queue) :
        intent.locale_id == "en_US" && intent.bot_version == "DRAFT" &&
        intent.dialog_code_hook[0].enabled && intent.fulfillment_code_hook[0].active &&
        !intent.fulfillment_code_hook[0].enabled
      ])
    )
    error_message = "Customer queue must retain COPPA=true and configure only the requested English intents with dialog hooks and active fulfillment."
  }

  assert {
    condition = (
      length(aws_lexv2models_intent.english_customer_queue["repeat"].sample_utterance) == 16 &&
      length(aws_lexv2models_intent.english_customer_queue["virtualQueue"].sample_utterance) == 10 &&
      length(aws_lexv2models_intent.english_customer_queue["voicemail"].sample_utterance) == 10 &&
      contains([for item in aws_lexv2models_intent.english_customer_queue["repeat"].sample_utterance : item.utterance], "i didn't hear that") &&
      contains([for item in aws_lexv2models_intent.english_customer_queue["virtualQueue"].sample_utterance : item.utterance], "hold my position in queue") &&
      contains([for item in aws_lexv2models_intent.english_customer_queue["voicemail"].sample_utterance : item.utterance], "I would like to leave a message")
    )
    error_message = "All 36 supplied utterances must be present in the appropriate intents."
  }

  assert {
    condition = (
      length(terraform_data.english_customer_queue_fallback) == 1 &&
      jsondecode(terraform_data.english_customer_queue_fallback[0].triggers_replace.configuration).intentId == "FALLBCKINT" &&
      jsondecode(terraform_data.english_customer_queue_fallback[0].triggers_replace.configuration).intentName == "FallbackIntent" &&
      jsondecode(terraform_data.english_customer_queue_fallback[0].triggers_replace.configuration).localeId == "en_US" &&
      jsondecode(terraform_data.english_customer_queue_fallback[0].triggers_replace.configuration).parentIntentSignature == "AMAZON.FallbackIntent" &&
      jsondecode(terraform_data.english_customer_queue_fallback[0].triggers_replace.configuration).dialogCodeHook.enabled &&
      jsondecode(terraform_data.english_customer_queue_fallback[0].triggers_replace.configuration).fulfillmentCodeHook.active &&
      !jsondecode(terraform_data.english_customer_queue_fallback[0].triggers_replace.configuration).fulfillmentCodeHook.enabled &&
      length(terraform_data.english_fallback) == 0 &&
      length(aws_lexv2models_intent.english_yesno) == 0 &&
      length(aws_lexv2models_intent.portuguese_yesno) == 0 &&
      length(aws_lexv2models_intent.spanish_yesno) == 0 &&
      length(awscc_lex_bot_alias.this) == 0
    )
    error_message = "Update the existing English fallback once, without adding survey intents, aliases or logging to this COPPA bot."
  }
}

run "customer_queue_intents_are_opt_in" {
  command = plan
  variables {
    enable_english_customer_queue_intents = false
  }
  assert {
    condition = (
      length(aws_lexv2models_intent.english_customer_queue) == 0 &&
      length(terraform_data.english_customer_queue_fallback) == 0 &&
      length(aws_lexv2models_intent.portuguese_customer_queue) == 0 &&
      length(terraform_data.portuguese_customer_queue_fallback) == 0 &&
      length(aws_lexv2models_intent.spanish_customer_queue) == 0 &&
      length(terraform_data.spanish_customer_queue_fallback) == 0
    )
    error_message = "Existing callers must remain unchanged when customer queue intents are disabled."
  }
}

run "customer_queue_requires_english" {
  command = plan
  variables {
    locale_ids = ["pt_BR", "es_419"]
  }
  expect_failures = [var.enable_english_customer_queue_intents]
}

run "customer_queue_and_yesno_repeat_cannot_collide" {
  command = plan
  variables {
    enable_english_yesno_intents = true
  }
  expect_failures = [var.enable_english_customer_queue_intents]
}

run "portuguese_and_english_customer_queue_intents" {
  command = plan
  variables {
    enable_portuguese_customer_queue_intents = true
  }

  assert {
    condition = (
      aws_lexv2models_bot.this.data_privacy[0].child_directed &&
      toset(keys(aws_lexv2models_intent.portuguese_customer_queue)) == toset(["repeat", "virtualQueue", "voicemail"]) &&
      length(aws_lexv2models_intent.english_customer_queue) == 3 &&
      alltrue([
        for intent in values(aws_lexv2models_intent.portuguese_customer_queue) :
        intent.locale_id == "pt_BR" && intent.bot_version == "DRAFT" &&
        intent.dialog_code_hook[0].enabled && intent.fulfillment_code_hook[0].active &&
        !intent.fulfillment_code_hook[0].enabled
      ])
    )
    error_message = "Portuguese customer queue intents must coexist with English and preserve COPPA and the requested hooks."
  }

  assert {
    condition = (
      length(aws_lexv2models_intent.portuguese_customer_queue["repeat"].sample_utterance) == 26 &&
      length(aws_lexv2models_intent.portuguese_customer_queue["virtualQueue"].sample_utterance) == 10 &&
      length(aws_lexv2models_intent.portuguese_customer_queue["voicemail"].sample_utterance) == 10 &&
      contains([for item in aws_lexv2models_intent.portuguese_customer_queue["repeat"].sample_utterance : item.utterance], "você pode repetir isso?") &&
      contains([for item in aws_lexv2models_intent.portuguese_customer_queue["repeat"].sample_utterance : item.utterance], "não ouvi isso") &&
      contains([for item in aws_lexv2models_intent.portuguese_customer_queue["repeat"].sample_utterance : item.utterance], "repete aí") &&
      contains([for item in aws_lexv2models_intent.portuguese_customer_queue["virtualQueue"].sample_utterance : item.utterance], "manter minha posição na fila") &&
      contains([for item in aws_lexv2models_intent.portuguese_customer_queue["virtualQueue"].sample_utterance : item.utterance], "quero receber uma ligação") &&
      contains([for item in aws_lexv2models_intent.portuguese_customer_queue["voicemail"].sample_utterance : item.utterance], "correio de voz por favor")
    )
    error_message = "All 46 Portuguese utterances and their UTF-8 accents must be preserved."
  }

  assert {
    condition = (
      length(terraform_data.portuguese_customer_queue_fallback) == 1 &&
      jsondecode(terraform_data.portuguese_customer_queue_fallback[0].triggers_replace.configuration).intentId == "FALLBCKINT" &&
      jsondecode(terraform_data.portuguese_customer_queue_fallback[0].triggers_replace.configuration).intentName == "FallbackIntent" &&
      jsondecode(terraform_data.portuguese_customer_queue_fallback[0].triggers_replace.configuration).localeId == "pt_BR" &&
      jsondecode(terraform_data.portuguese_customer_queue_fallback[0].triggers_replace.configuration).parentIntentSignature == "AMAZON.FallbackIntent" &&
      jsondecode(terraform_data.portuguese_customer_queue_fallback[0].triggers_replace.configuration).dialogCodeHook.enabled &&
      jsondecode(terraform_data.portuguese_customer_queue_fallback[0].triggers_replace.configuration).fulfillmentCodeHook.active &&
      !jsondecode(terraform_data.portuguese_customer_queue_fallback[0].triggers_replace.configuration).fulfillmentCodeHook.enabled &&
      length(terraform_data.english_customer_queue_fallback) == 1 &&
      length(terraform_data.portuguese_fallback) == 0 &&
      length(aws_lexv2models_intent.portuguese_yesno) == 0 &&
      length(awscc_lex_bot_alias.this) == 0
    )
    error_message = "Update the existing Portuguese fallback once without changing English fallback or adding aliases or survey intents."
  }
}

run "portuguese_customer_queue_can_run_independently" {
  command = plan
  variables {
    locale_ids                               = ["pt_BR"]
    enable_english_customer_queue_intents    = false
    enable_portuguese_customer_queue_intents = true
  }
  assert {
    condition = (
      length(aws_lexv2models_intent.portuguese_customer_queue) == 3 &&
      length(terraform_data.portuguese_customer_queue_fallback) == 1 &&
      length(aws_lexv2models_intent.english_customer_queue) == 0 &&
      length(terraform_data.english_customer_queue_fallback) == 0
    )
    error_message = "Portuguese customer queue intents must not require English."
  }
}

run "portuguese_customer_queue_requires_its_locale" {
  command = plan
  variables {
    locale_ids                               = ["en_US", "es_419"]
    enable_portuguese_customer_queue_intents = true
  }
  expect_failures = [var.enable_portuguese_customer_queue_intents]
}

run "portuguese_customer_queue_and_yesno_repeat_cannot_collide" {
  command = plan
  variables {
    enable_portuguese_customer_queue_intents = true
    enable_portuguese_yesno_intents          = true
  }
  expect_failures = [var.enable_portuguese_customer_queue_intents]
}

run "all_three_customer_queue_languages" {
  command = plan
  variables {
    enable_portuguese_customer_queue_intents = true
    enable_spanish_customer_queue_intents    = true
  }

  assert {
    condition = (
      aws_lexv2models_bot.this.data_privacy[0].child_directed &&
      toset(keys(aws_lexv2models_intent.spanish_customer_queue)) == toset(["repeat", "virtualQueue", "voicemail"]) &&
      length(aws_lexv2models_intent.english_customer_queue) == 3 &&
      length(aws_lexv2models_intent.portuguese_customer_queue) == 3 &&
      alltrue([
        for intent in values(aws_lexv2models_intent.spanish_customer_queue) :
        intent.locale_id == "es_419" && intent.bot_version == "DRAFT" &&
        intent.dialog_code_hook[0].enabled && intent.fulfillment_code_hook[0].active &&
        !intent.fulfillment_code_hook[0].enabled
      ])
    )
    error_message = "Spanish customer queue intents must coexist with English and Portuguese and preserve COPPA and the requested hooks."
  }

  assert {
    condition = (
      length(aws_lexv2models_intent.spanish_customer_queue["repeat"].sample_utterance) == 15 &&
      length(aws_lexv2models_intent.spanish_customer_queue["virtualQueue"].sample_utterance) == 10 &&
      length(aws_lexv2models_intent.spanish_customer_queue["voicemail"].sample_utterance) == 10 &&
      contains([for item in aws_lexv2models_intent.spanish_customer_queue["repeat"].sample_utterance : item.utterance], "¿podrías repetir?") &&
      contains([for item in aws_lexv2models_intent.spanish_customer_queue["repeat"].sample_utterance : item.utterance], "no escuché eso") &&
      contains([for item in aws_lexv2models_intent.spanish_customer_queue["virtualQueue"].sample_utterance : item.utterance], "llámame de vuelta") &&
      contains([for item in aws_lexv2models_intent.spanish_customer_queue["virtualQueue"].sample_utterance : item.utterance], "mantener mi posición en la fila") &&
      contains([for item in aws_lexv2models_intent.spanish_customer_queue["voicemail"].sample_utterance : item.utterance], "buzón de voz") &&
      contains([for item in aws_lexv2models_intent.spanish_customer_queue["voicemail"].sample_utterance : item.utterance], "Me gustaría dejar un mensaje")
    )
    error_message = "All 35 Spanish utterances, accents and inverted question marks must be preserved."
  }

  assert {
    condition = (
      length(terraform_data.spanish_customer_queue_fallback) == 1 &&
      jsondecode(terraform_data.spanish_customer_queue_fallback[0].triggers_replace.configuration).intentId == "FALLBCKINT" &&
      jsondecode(terraform_data.spanish_customer_queue_fallback[0].triggers_replace.configuration).intentName == "FallbackIntent" &&
      jsondecode(terraform_data.spanish_customer_queue_fallback[0].triggers_replace.configuration).localeId == "es_419" &&
      jsondecode(terraform_data.spanish_customer_queue_fallback[0].triggers_replace.configuration).parentIntentSignature == "AMAZON.FallbackIntent" &&
      jsondecode(terraform_data.spanish_customer_queue_fallback[0].triggers_replace.configuration).dialogCodeHook.enabled &&
      jsondecode(terraform_data.spanish_customer_queue_fallback[0].triggers_replace.configuration).fulfillmentCodeHook.active &&
      !jsondecode(terraform_data.spanish_customer_queue_fallback[0].triggers_replace.configuration).fulfillmentCodeHook.enabled &&
      length(terraform_data.english_customer_queue_fallback) == 1 &&
      length(terraform_data.portuguese_customer_queue_fallback) == 1 &&
      length(terraform_data.spanish_fallback) == 0 &&
      length(aws_lexv2models_intent.spanish_yesno) == 0 &&
      length(awscc_lex_bot_alias.this) == 0
    )
    error_message = "Update the existing Spanish fallback once, retaining the other locales without adding survey intents or aliases."
  }
}

run "spanish_customer_queue_can_run_independently" {
  command = plan
  variables {
    locale_ids                            = ["es_419"]
    enable_english_customer_queue_intents = false
    enable_spanish_customer_queue_intents = true
  }
  assert {
    condition = (
      length(aws_lexv2models_intent.spanish_customer_queue) == 3 &&
      length(terraform_data.spanish_customer_queue_fallback) == 1 &&
      length(aws_lexv2models_intent.english_customer_queue) == 0 &&
      length(terraform_data.english_customer_queue_fallback) == 0 &&
      length(aws_lexv2models_intent.portuguese_customer_queue) == 0 &&
      length(terraform_data.portuguese_customer_queue_fallback) == 0
    )
    error_message = "Spanish customer queue intents must not require English or Portuguese."
  }
}

run "spanish_customer_queue_requires_its_locale" {
  command = plan
  variables {
    locale_ids                            = ["en_US", "pt_BR"]
    enable_spanish_customer_queue_intents = true
  }
  expect_failures = [var.enable_spanish_customer_queue_intents]
}

run "spanish_customer_queue_and_yesno_repeat_cannot_collide" {
  command = plan
  variables {
    enable_spanish_customer_queue_intents = true
    enable_spanish_yesno_intents          = true
  }
  expect_failures = [var.enable_spanish_customer_queue_intents]
}

run "customer_queue_publication_requires_all_languages" {
  command = plan
  variables {
    publish_customer_queue_version = true
  }
  expect_failures = [var.publish_customer_queue_version]
}
