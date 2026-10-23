# Spanish (LATAM) customer queue intents. Reuses data.aws_region.current and
# local.spanish_fallback_configuration from the existing intent files.
# These resources configure DRAFT intents only. Before runtime testing, build
# es_419, configure the intended Lambda on the bot alias and grant invoke permission.

locals {
  spanish_customer_queue_intents = {
    repeat = [
      "repite",
      "¿podrías repetir?",
      "por favor, repite",
      "¿puedes repetir eso?",
      "¿podrías repetir, por favor?",
      "repite la pregunta",
      "no escuché eso",
      "se me pasó eso",
      "dilo otra vez",
      "¿qué fue eso?",
      "perdón",
      "repítelo",
      "¿puedes decirlo otra vez?",
      "por favor, dilo otra vez",
      "repítelo, por favor",
    ]

    virtualQueue = [
      "fila virtual",
      "llamada de retorno",
      "llámame de vuelta",
      "quiero que me llamen de vuelta",
      "solicitar una llamada de retorno",
      "mantener mi lugar en la fila",
      "mantener mi posición en la fila",
      "guardar mi lugar en la fila",
      "que alguien me llame de vuelta",
      "llamada de retorno, por favor",
    ]

    voicemail = [
      "buzón de voz",
      "dejar un mensaje de voz",
      "Quiero dejar un mensaje de voz",
      "déjame dejar un mensaje",
      "dejar un mensaje",
      "tomar un mensaje",
      "enviar un mensaje de voz",
      "grabar un mensaje",
      "Me gustaría dejar un mensaje",
      "buzón de voz, por favor",
    ]
  }
}

resource "aws_lexv2models_intent" "spanish_customer_queue" {
  for_each = (
    var.enable_spanish_customer_queue_intents
    ? local.spanish_customer_queue_intents
    : {}
  )

  bot_id      = aws_lexv2models_bot.this.id
  bot_version = "DRAFT"
  locale_id   = aws_lexv2models_bot_locale.this["es_419"].locale_id
  name        = each.key

  dialog_code_hook {
    enabled = true
  }

  # Fulfillment is active; fulfillment Lambda invocation is separate.
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

# Update the existing es_419 FALLBCKINT instead of creating a duplicate.
# The shared configuration enables dialog initialization/validation, with
# fulfillment active and fulfillment Lambda invocation disabled.
# Fallback Lambda execution requires fulfillmentCodeHook.enabled=true.
# Requires Bash, AWS CLI and lex:UpdateIntent permission on the runner.
resource "terraform_data" "spanish_customer_queue_fallback" {
  count = var.enable_spanish_customer_queue_intents ? 1 : 0

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
    aws_lexv2models_intent.spanish_customer_queue,
  ]
}
