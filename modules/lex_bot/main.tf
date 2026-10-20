terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

resource "aws_iam_role" "lex" {
  name = "${var.bot_name}-lex-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lexv2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "speech" {
  name = "lex-speech"
  role = aws_iam_role.lex.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["polly:SynthesizeSpeech"]
      Resource = "*"
    }]
  })
}

resource "aws_lexv2models_bot" "this" {
  name                        = var.bot_name
  role_arn                    = aws_iam_role.lex.arn
  idle_session_ttl_in_seconds = 300

  data_privacy {
    child_directed = var.child_directed
  }

  depends_on = [aws_iam_role_policy.speech]
}

resource "aws_lexv2models_bot_locale" "this" {
  for_each = var.locale_ids

  bot_id                           = aws_lexv2models_bot.this.id
  bot_version                      = "DRAFT"
  locale_id                        = each.value
  n_lu_intent_confidence_threshold = 0.40
}
