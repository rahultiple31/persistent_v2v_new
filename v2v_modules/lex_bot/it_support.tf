# Requires Python 3 and AWS CLI v2 supporting qInConnectIntentConfiguration.
resource "aws_iam_role_policy" "it_support_qinconnect" {
  count = var.it_support_configuration != null ? 1 : 0

  name = "${var.bot_name}-qinconnect"
  role = aws_iam_role.lex.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "QInConnectAssistant"
        Effect = "Allow"
        Action = [
          "wisdom:CreateSession",
          "wisdom:GetAssistant",
        ]
        Resource = [
          var.it_support_configuration.assistant_arn,
          "${var.it_support_configuration.assistant_arn}/*",
        ]
      },
      {
        Sid    = "QInConnectSessions"
        Effect = "Allow"
        Action = [
          "wisdom:SendMessage",
          "wisdom:GetNextMessage",
        ]
        Resource = [
          "${replace(var.it_support_configuration.assistant_arn, ":assistant/", ":session/")}/*",
        ]
      }
    ]
  })

  # An assistant using a customer-managed key also requires key-specific KMS permissions.
}

resource "terraform_data" "it_support_configuration" {
  count = var.it_support_configuration != null ? 1 : 0

  triggers_replace = {
    bot_id         = aws_lexv2models_bot.this.id
    bot_name       = var.bot_name
    child_directed = var.child_directed
    configuration  = jsonencode(var.it_support_configuration)
    role_policy    = aws_iam_role_policy.it_support_qinconnect[0].policy
    script_hash    = filesha256("${path.module}/configure_it_support.py")

    locale_configuration = jsonencode({
      for locale, settings in aws_lexv2models_bot_locale.this :
      locale => {
        confidence_threshold = settings.n_lu_intent_confidence_threshold
        voice_settings       = settings.voice_settings
      }
    })
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "python3 \"$LEX_CONFIGURATION_SCRIPT\""

    environment = {
      LEX_CONFIGURATION_SCRIPT = abspath("${path.module}/configure_it_support.py")
      LEX_BOT_ID               = aws_lexv2models_bot.this.id

      LEX_CONFIGURATION = jsonencode(merge(
        var.it_support_configuration,
        {
          bot_name = var.bot_name
          locales  = sort(tolist(var.locale_ids))
        }
      ))

      AWS_REGION          = "us-east-1"
      AWS_PAGER           = ""
      AWS_CLI_AUTO_PROMPT = "off"
    }
  }

  depends_on = [
    aws_lexv2models_bot.this,
    aws_lexv2models_bot_locale.this,
    aws_iam_role_policy.it_support_qinconnect,
  ]
}

# Non-English Q responses require localized assistant self-service prompts.
# CLI-managed intent and alias settings are refreshed when the triggers change.
