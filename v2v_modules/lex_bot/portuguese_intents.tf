# pt_BR yes/no survey intents.
# Before testing, configure Lambda and invoke permission on the bot alias,
# then build this locale. Numeric utterances do not configure keypad handling.

locals {
  portuguese_yesno_intents = {
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

    yes = [
      "sim",
      "claro",
      "com certeza",
      "isso mesmo",
      "correto",
      "certo",
      "ok",
      "okay",
      "tudo bem",
      "está bem",
      "sem problemas",
      "por que não?",
      "afirmativo",
      "absolutamente",
      "sim, claro",
      "sim, com certeza",
      "sim, por favor",
      "sim, estou satisfeito",
      "sim, estou satisfeita",
      "estou satisfeito",
      "estou satisfeita",
      "satisfeito",
      "satisfeita",
      "foi bom",
      "foi ótimo",
      "gostei",
      "achei bom",
      "está correto",
      "isso está correto",
      "está certo",
      "perfeito",
      "positivo",
    ]

    dtmf = [
      "1",
      "2",
    ]

    no = [
      "não",
      "não mesmo",
      "de jeito nenhum",
      "claro que não",
      "negativo",
      "recuso",
      "não quero",
      "eu disse não",
      "não, obrigado",
      "não, obrigada",
      "não não",
      "de forma alguma",
      "nem pensar",
      "não estou satisfeito",
      "não estou satisfeita",
      "estou insatisfeito",
      "estou insatisfeita",
      "insatisfeito",
      "insatisfeita",
      "não gostei",
      "foi ruim",
      "não foi bom",
      "não está correto",
      "incorreto",
      "não concordo",
      "prefiro não",
    ]

  }

  portuguese_fallback_configuration = jsonencode({
    botId                 = aws_lexv2models_bot.this.id
    botVersion            = "DRAFT"
    localeId              = "pt_BR"
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

resource "aws_lexv2models_intent" "portuguese_yesno" {
  for_each = var.enable_portuguese_yesno_intents ? local.portuguese_yesno_intents : {}

  bot_id      = aws_lexv2models_bot.this.id
  bot_version = "DRAFT"
  locale_id   = aws_lexv2models_bot_locale.this["pt_BR"].locale_id
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
resource "terraform_data" "portuguese_fallback" {
  count = var.enable_portuguese_yesno_intents ? 1 : 0

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
    aws_lexv2models_intent.portuguese_yesno,
  ]
}
