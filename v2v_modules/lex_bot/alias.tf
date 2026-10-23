resource "aws_iam_role_policy" "alias_text_logs" {
  count = var.alias_configuration != null ? 1 : 0

  name = "${var.bot_name}-text-logs"
  role = aws_iam_role.lex.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${trimsuffix(var.alias_configuration.text_log_group_arn, ":*")}:*"
    }]
  })
}

# Preserve the original version and publish the COPPA=false snapshot separately.
# This snapshot contains all three DRAFT locales. AWS assigns Version 1 only
# on first-ever publication; existing immutable versions cannot be overwritten.
resource "aws_lexv2models_bot_version" "alias_text_logs" {
  count = var.alias_configuration != null ? 1 : 0

  bot_id = aws_lexv2models_bot.this.id

  description = var.publish_customer_queue_version ? (
    "Customer queue bot with COPPA=false for alias text logging"
  ) : "Survey bot with COPPA=false for alias text logging"

  locale_specification = {
    for locale in ["en_US", "es_419", "pt_BR"] : locale => {
      source_bot_version = "DRAFT"
    }
  }

  depends_on = [
    terraform_data.yesno_locale_build,
    aws_lexv2models_bot_version.yesno_version_1,
    terraform_data.customer_queue_locale_build,
  ]
}

resource "awscc_lex_bot_alias" "this" {
  count = var.alias_configuration != null ? 1 : 0

  bot_id         = aws_lexv2models_bot.this.id
  bot_version    = aws_lexv2models_bot_version.alias_text_logs[0].bot_version
  bot_alias_name = var.alias_configuration.name
  description    = var.publish_customer_queue_version ? "Customer queue alias: English, Spanish LATAM, Portuguese BR" : "Yes/no survey alias: English, Spanish LATAM, Portuguese BR"

  bot_alias_locale_settings = [
    for locale in sort(tolist(var.locale_ids)) : {
      locale_id = locale
      bot_alias_locale_setting = {
        enabled = true
        code_hook_specification = {
          lambda_code_hook = {
            code_hook_interface_version = "1.0"
            lambda_arn                  = var.alias_configuration.lambda_function_arn
          }
        }
      }
    }
  ]

  conversation_log_settings = {
    text_log_settings = [{
      enabled = true
      destination = {
        cloudwatch = {
          cloudwatch_log_group_arn = trimsuffix(var.alias_configuration.text_log_group_arn, ":*")
          log_prefix               = var.alias_configuration.name
        }
      }
    }]
    audio_log_settings = []
  }

  depends_on = [aws_iam_role_policy.alias_text_logs]
}

resource "aws_lambda_permission" "lex_alias" {
  count = var.alias_configuration != null ? 1 : 0

  statement_id   = "AllowLex-${var.alias_configuration.name}"
  action         = "lambda:InvokeFunction"
  function_name  = var.alias_configuration.lambda_function_arn
  principal      = "lexv2.amazonaws.com"
  source_arn     = awscc_lex_bot_alias.this[0].arn
  source_account = split(":", awscc_lex_bot_alias.this[0].arn)[4]

  # An unqualified Lambda function ARN invokes $LATEST.
}

resource "awscc_lex_resource_policy" "connect" {
  count = var.alias_configuration != null ? 1 : 0

  resource_arn = awscc_lex_bot_alias.this[0].arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid = format(
        "connect-%s-%s",
        split(":", var.alias_configuration.connect_instance_arn)[3],
        split("/", var.alias_configuration.connect_instance_arn)[1]
      )
      Effect = "Allow"
      Principal = {
        Service = "connect.amazonaws.com"
      }
      Action = [
        "lex:RecognizeText",
        "lex:StartConversation",
        "lex:RecognizeMessageAsync",
      ]
      Resource = awscc_lex_bot_alias.this[0].arn
      Condition = {
        StringEquals = {
          "AWS:SourceAccount" = split(":", var.alias_configuration.connect_instance_arn)[4]
        }
        ArnEquals = {
          "AWS:SourceArn" = var.alias_configuration.connect_instance_arn
        }
      }
    }]
  })
}
