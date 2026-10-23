# Portuguese (Brazil) customer queue intents. Reuses data.aws_region.current
# and local.portuguese_fallback_configuration from the existing intent files.
# These resources configure DRAFT intents only. Before runtime testing, build
# pt_BR, configure the intended Lambda on the bot alias and grant invoke permission.

locals {
  portuguese_customer_queue_intents = {
    repeat = [
      "repita",
      "pode repetir?",
      "por favor, repita",
      "você pode repetir isso?",
      "diga isso de novo",
      "poderia repetir, por favor?",
      "repita a pergunta",
      "não ouvi isso",
      "não consegui ouvir",
      "diga novamente",
      "como é?",
      "perdão?",
      "desculpe?",
      "pode dizer de novo?",
      "por favor, diga novamente",
      "repita, por favor",
      "não entendi",
      "não ouvi direito",
      "pode falar novamente?",
      "fale de novo",
      "repete aí",
      "o que você disse?",
      "como?",
      "desculpa, pode repetir?",
      "não peguei essa parte",
      "pode repetir a pergunta?",
    ]

    virtualQueue = [
      "retorno de chamada",
      "ligar de volta",
      "quero um retorno de chamada",
      "quero que me liguem",
      "manter minha posição na fila",
      "guardar meu lugar na fila",
      "me ligue de volta",
      "retorno por favor",
      "quero receber uma ligação",
      "chamada de retorno",
    ]

    voicemail = [
      "caixa postal",
      "correio de voz",
      "quero deixar uma mensagem",
      "deixar uma mensagem",
      "deixar recado",
      "gravar uma mensagem",
      "mensagem de voz",
      "quero gravar uma mensagem",
      "correio de voz por favor",
      "deixar um correio de voz",
    ]
  }
}

resource "aws_lexv2models_intent" "portuguese_customer_queue" {
  for_each = (
    var.enable_portuguese_customer_queue_intents
    ? local.portuguese_customer_queue_intents
    : {}
  )

  bot_id      = aws_lexv2models_bot.this.id
  bot_version = "DRAFT"
  locale_id   = aws_lexv2models_bot_locale.this["pt_BR"].locale_id
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

# Update the existing pt_BR FALLBCKINT instead of creating a duplicate.
# The shared configuration enables dialog initialization/validation, with
# fulfillment active and fulfillment Lambda invocation disabled.
# Fallback Lambda execution requires fulfillmentCodeHook.enabled=true.
# Requires Bash, AWS CLI and lex:UpdateIntent permission on the runner.
resource "terraform_data" "portuguese_customer_queue_fallback" {
  count = var.enable_portuguese_customer_queue_intents ? 1 : 0

  triggers_replace = {
    configuration = local.portuguese_fallback_configuration
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
      FALLBACK_CONFIGURATION = local.portuguese_fallback_configuration
      AWS_REGION             = data.aws_region.current.region
      AWS_PAGER              = ""
      AWS_CLI_AUTO_PROMPT    = "off"
    }
  }

  depends_on = [
    aws_lexv2models_bot_locale.this,
    aws_lexv2models_intent.portuguese_customer_queue,
  ]
}
