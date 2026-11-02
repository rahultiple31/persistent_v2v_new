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
        detail        = { bucket = { name = [aws_s3_bucket.this["recordings"].bucket] } }
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
