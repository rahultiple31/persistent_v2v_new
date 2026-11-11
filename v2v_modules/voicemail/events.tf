# EventBridge rules on the default bus; patterns copied from the voicemail-v2v rules.

locals {
  rules = {
    PackagerRule = {
      function = "Packager"
      pattern = {
        source        = ["aws.s3"]
        "detail-type" = ["Object Created"]
        detail        = { bucket = { name = [aws_s3_bucket.this["transcripts"].bucket] } }
      }
    }
    TranscriberRule = {
      function = "Transcriber"
      pattern = {
        source        = ["aws.s3"]
        "detail-type" = ["Object Created"]
        detail        = { bucket = { name = [aws_s3_bucket.this["recording"].bucket] } }
      }
    }
    TranscribeErrorHandlerRule = {
      function = "TranscribeErrorHandler"
      pattern = {
        source        = ["aws.transcribe"]
        "detail-type" = ["Transcribe Job State Change"]
        detail = {
          TranscriptionJobName   = [{ prefix = "vmx3_" }]
          TranscriptionJobStatus = ["FAILED"]
        }
      }
    }
  }
}

resource "aws_cloudwatch_event_rule" "this" {
  for_each = local.rules

  name           = "${local.prefix}-${each.key}"
  event_bus_name = "default"
  state          = "ENABLED"
  event_pattern  = jsonencode(each.value.pattern)
  tags           = merge(var.tags, { Name = "${local.prefix}-${each.key}" })
}

resource "aws_cloudwatch_event_target" "this" {
  for_each = local.rules

  rule           = aws_cloudwatch_event_rule.this[each.key].name
  event_bus_name = "default"
  target_id      = each.value.function
  arn            = aws_lambda_function.this[each.value.function].arn
}

resource "aws_lambda_permission" "events" {
  for_each = local.rules

  statement_id  = "AllowEventBridge-${each.key}"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.this[each.value.function].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.this[each.key].arn
}

# S3 invoke permissions. The buckets publish to EventBridge (rules above), so
# these allow, but do not create, direct S3 notifications. Both functions are
# scoped to the transcript bucket at QA's request (Nov 2026). DEV-SSO scopes
# the Transcriber to its recordings bucket instead; the Transcriber is still
# triggered by new recordings through TranscriberRule.
locals {
  s3_invoke_permissions = {
    Transcriber = { sid = "AllowS3-TranscriptBucket", bucket = "transcripts" }
    Packager    = { sid = "AllowS3-TranscriptBucket", bucket = "transcripts" }
  }
}

resource "aws_lambda_permission" "s3" {
  for_each = local.s3_invoke_permissions

  statement_id   = each.value.sid
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.this[each.key].function_name
  principal      = "s3.amazonaws.com"
  source_account = local.account_id
  source_arn     = aws_s3_bucket.this[each.value.bucket].arn
}
