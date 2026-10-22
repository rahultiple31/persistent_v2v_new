# es_419 yes/no survey intents.
# Before testing, configure Lambda and invoke permission on the bot alias,
# then build this locale. Numeric utterances do not configure keypad handling.

locals {
  spanish_yesno_intents = {
    repeat = [
      "repite",
      "¿podrías repetir?",
      "por favor, repite",
      "¿puedes repetir eso?",
      "dilo otra vez",
      "¿podrías repetir, por favor?",
      "repite la pregunta",
      "no escuché eso",
      "se me pasó eso",
      "¿qué fue eso?",
      "perdón",
      "repítelo",
      "¿puedes decirlo otra vez?",
      "por favor, dilo otra vez",
      "repítelo, por favor",
    ]

    yes = [
      "sí",
      "ya",
      "yupp",
      "claro",
      "bien",
      "me parece bien",
      "sí, claro",
      "sí, ¿por qué no?",
      "afirmativo",
      "por supuesto",
      "correcto",
      "de acuerdo",
      "sí, por favor",
      "sí, estoy satisfecho",
    ]

    dtmf = [
      "1",
      "2",
    ]

    no = [
      "nooo",
      "no",
      "nada",
      "no quiero",
      "ya dije que no",
      "no, gracias",
      "no, no",
      "rechazar",
      "negativo",
      "no estoy satisfecho",
    ]

  }

  spanish_fallback_configuration = jsonencode({
    botId                 = aws_lexv2models_bot.this.id
    botVersion            = "DRAFT"
    localeId              = "es_419"
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

resource "aws_lexv2models_intent" "spanish_yesno" {
  for_each = var.enable_spanish_yesno_intents ? local.spanish_yesno_intents : {}

  bot_id      = aws_lexv2models_bot.this.id
  bot_version = "DRAFT"
  locale_id   = aws_lexv2models_bot_locale.this["es_419"].locale_id
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
resource "terraform_data" "spanish_fallback" {
  count = var.enable_spanish_yesno_intents ? 1 : 0

  triggers_replace = {
    configuration = local.spanish_fallback_configuration
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
      FALLBACK_CONFIGURATION = local.spanish_fallback_configuration
      AWS_REGION             = data.aws_region.current.region
      AWS_PAGER              = ""
      AWS_CLI_AUTO_PROMPT    = "off"
    }
  }

  depends_on = [
    aws_lexv2models_bot_locale.this,
    aws_lexv2models_intent.spanish_yesno,
  ]
}
