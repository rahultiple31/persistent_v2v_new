# Requires Bash and AWS CLI on the Terraform runner.
resource "terraform_data" "customer_queue_locale_build" {
  count = var.publish_customer_queue_version ? 1 : 0

  triggers_replace = {
    bot_id         = aws_lexv2models_bot.this.id
    region         = data.aws_region.current.region
    child_directed = var.child_directed

    configuration_hash = sha256(jsonencode({
      english_intents    = local.english_customer_queue_intents
      portuguese_intents = local.portuguese_customer_queue_intents
      spanish_intents    = local.spanish_customer_queue_intents

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
    aws_lexv2models_intent.english_customer_queue,
    aws_lexv2models_intent.portuguese_customer_queue,
    aws_lexv2models_intent.spanish_customer_queue,
    terraform_data.english_customer_queue_fallback,
    terraform_data.portuguese_customer_queue_fallback,
    terraform_data.spanish_customer_queue_fallback,
  ]
}

# Published versions are immutable. Later DRAFT edits need a new version
# and an alias update; rebuilding alone does not replace a published snapshot.
