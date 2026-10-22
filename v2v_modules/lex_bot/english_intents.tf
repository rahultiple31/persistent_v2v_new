# en_US yes/no survey intents.
# Before testing, configure Lambda and invoke permission on the bot alias,
# then build this locale. Numeric utterances do not configure keypad handling.

data "aws_region" "current" {}

locals {
  english_yesno_intents = {
    repeat = [
      "repeat",
      "could you repeat",
      "please repeat",
      "can you repeat that",
      "say that again",
      "could you please repeat",
      "repeat the question",
      "i didn't hear that",
      "i missed that",
      "say it again",
      "what was that",
      "pardon",
      "come again",
      "can you say that again",
      "please say that again",
      "repeat please",
    ]

    yes = [
      "yes",
      "ya",
      "yupp",
      "yeah",
      "sure",
      "ok",
      "fine",
      "sounds good",
      "yes sure",
      "yea sure",
      "yes why not",
      "affirmative",
      "absolutely",
      "correct",
      "okay",
      "yes please",
      "yep",
      "yes I am satisfied",
    ]

    dtmf = [
      "1",
      "2",
    ]

    no = [
      "no",
      "nahh",
      "nope",
      "nada",
      "do not want",
      "i said no",
      "nope thanks",
      "no no",
      "deny",
      "negative",
      "not satisfied",
    ]

  }

  english_fallback_configuration = jsonencode({
    botId                 = aws_lexv2models_bot.this.id
    botVersion            = "DRAFT"
    localeId              = "en_US"
    intentId              = "FALLBCKINT"
    intentName            = "FallbackIntent"
    description           = "Default intent when no other intent matches"
    parentIntentSignature = "AMAZON.FallbackIntent"

    dialogCodeHook = {
      enabled = true
    }

    # Initialization/validation uses the dialog hook above.
    # Enable the fulfillment Lambda separately if required.
    fulfillmentCodeHook = {
      active  = true
      enabled = false
    }
  })
}

resource "aws_lexv2models_intent" "english_yesno" {
  for_each = var.enable_english_yesno_intents ? local.english_yesno_intents : {}

  bot_id      = aws_lexv2models_bot.this.id
  bot_version = "DRAFT"
  locale_id   = aws_lexv2models_bot_locale.this["en_US"].locale_id
  name        = each.key

  dialog_code_hook {
    enabled = true
  }

  # Fulfillment stays active; its Lambda invocation is a separate setting.
  fulfillment_code_hook {
    active  = true
    enabled = false
  }

  dynamic "sample_utterance" {
    for_each = toset(each.value)

    content {
      utterance = sample_utterance.value
    }
  }
}

# Lex creates FALLBCKINT with the locale; update it without creating a duplicate.
# The runner requires Bash, AWS CLI, and permission to update this bot's intents.
# Fallback Lambda execution requires fulfillmentCodeHook.enabled=true.
resource "terraform_data" "english_fallback" {
  count = var.enable_english_yesno_intents ? 1 : 0

  triggers_replace = {
    configuration = local.english_fallback_configuration
    region        = data.aws_region.current.region
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]

    command = <<-BASH
      set -euo pipefail

      aws lexv2-models update-intent \
        --cli-input-json "$FALLBACK_CONFIGURATION" \
        --region "$AWS_REGION" \
        --query intentId \
        --output text \
        --no-cli-pager > /dev/null
    BASH

    environment = {
      FALLBACK_CONFIGURATION = local.english_fallback_configuration
      AWS_REGION             = data.aws_region.current.region
      AWS_PAGER              = ""
      AWS_CLI_AUTO_PROMPT    = "off"
    }
  }

  depends_on = [
    aws_lexv2models_bot_locale.this,
    aws_lexv2models_intent.english_yesno,
  ]
}
