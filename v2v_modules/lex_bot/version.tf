# Keep the existing English, Portuguese, and Spanish intent files.
# Requires Bash and AWS CLI on the Terraform runner.
resource "terraform_data" "yesno_locale_build" {
  count = var.publish_yesno_version ? 1 : 0

  triggers_replace = {
    child_directed = var.child_directed
    bot_id         = aws_lexv2models_bot.this.id
    region         = data.aws_region.current.region
    configuration_hash = sha256(jsonencode({
      english_intents    = local.english_yesno_intents
      portuguese_intents = local.portuguese_yesno_intents
      spanish_intents    = local.spanish_yesno_intents
      fallback_configurations = [
        local.english_fallback_configuration,
        local.portuguese_fallback_configuration,
        local.spanish_fallback_configuration,
      ]
      locale_settings = {
        for locale in ["en_US", "pt_BR", "es_419"] : locale => {
          confidence_threshold = aws_lexv2models_bot_locale.this[locale].n_lu_intent_confidence_threshold
          voice_settings       = aws_lexv2models_bot_locale.this[locale].voice_settings
        }
      }
    }))
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]

    command = <<-BASH
      set -euo pipefail

      for locale in en_US pt_BR es_419; do
        aws lexv2-models build-bot-locale \
          --bot-id "$BOT_ID" \
          --bot-version DRAFT \
          --locale-id "$locale" \
          --region "$AWS_REGION" \
          --no-cli-pager > /dev/null

        aws lexv2-models wait bot-locale-built \
          --bot-id "$BOT_ID" \
          --bot-version DRAFT \
          --locale-id "$locale" \
          --region "$AWS_REGION" \
          --no-cli-pager
      done
    BASH

    environment = {
      BOT_ID              = aws_lexv2models_bot.this.id
      AWS_REGION          = data.aws_region.current.region
      AWS_PAGER           = ""
      AWS_CLI_AUTO_PROMPT = "off"
    }
  }

  depends_on = [
    aws_lexv2models_intent.english_yesno,
    aws_lexv2models_intent.portuguese_yesno,
    aws_lexv2models_intent.spanish_yesno,
    terraform_data.english_fallback,
    terraform_data.portuguese_fallback,
    terraform_data.spanish_fallback,
  ]
}

# AWS assigns the number: the first ever published version is "1".
# If earlier versions exist or were deleted, AWS assigns the next number.
# Published versions are immutable; later DRAFT edits do not change this snapshot.
resource "aws_lexv2models_bot_version" "yesno_version_1" {
  count = var.publish_yesno_version ? 1 : 0

  bot_id      = aws_lexv2models_bot.this.id
  description = "Initial survey version: English (US), Portuguese (BR), Spanish (LATAM)"

  locale_specification = {
    for locale in ["en_US", "pt_BR", "es_419"] : locale => {
      source_bot_version = "DRAFT"
    }
  }

  depends_on = [terraform_data.yesno_locale_build]
}

# Optional alias_configuration attaches an alias to the separate logging snapshot.
