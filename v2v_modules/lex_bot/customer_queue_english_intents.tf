# English customer queue intents. Reuses data.aws_region.current and
# local.english_fallback_configuration from english_intents.tf.
# Build en_US after applying. Configure the intended Lambda on the bot alias
# and grant invoke permission before runtime testing.
# This configures DRAFT intents; it does not publish a version or create an alias.

locals {
  english_customer_queue_intents = {
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

    virtualQueue = [
      "virtual queue",
      "callback",
      "call me back",
      "I want a callback",
      "request a callback",
      "keep my place in line",
      "hold my position in queue",
      "save my place in queue",
      "have someone call me back",
      "callback please",
    ]

    voicemail = [
      "voicemail",
      "leave a voicemail",
      "I want to leave a voicemail",
      "let me leave a message",
      "leave a message",
      "take a message",
      "send a voicemail",
      "record a message",
      "I would like to leave a message",
      "voicemail please",
    ]
  }
}

resource "aws_lexv2models_intent" "english_customer_queue" {
  for_each = (
    var.enable_english_customer_queue_intents
    ? local.english_customer_queue_intents
    : {}
  )

  bot_id      = aws_lexv2models_bot.this.id
  bot_version = "DRAFT"
  locale_id   = aws_lexv2models_bot_locale.this["en_US"].locale_id
  name        = each.key

  dialog_code_hook {
    enabled = true
  }

  # Initialization/validation is enabled above; fulfillment Lambda is separate.
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

# Update Lex's existing FALLBCKINT instead of creating a duplicate.
# The shared configuration enables dialog initialization/validation and keeps
# fulfillment active with fulfillment Lambda invocation disabled.
# Fallback Lambda execution requires fulfillmentCodeHook.enabled=true.
# Requires Bash, AWS CLI and lex:UpdateIntent permission on the runner.
resource "terraform_data" "english_customer_queue_fallback" {
  count = var.enable_english_customer_queue_intents ? 1 : 0

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
    aws_lexv2models_intent.english_customer_queue,
  ]
}
