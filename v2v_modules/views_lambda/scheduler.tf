# Reuse the existing Scheduler execution role.
data "aws_iam_role" "warmup_scheduler" {
  name = var.warmup_scheduler_role_name
}

# Allow the existing role to invoke this Lambda.
resource "aws_iam_role_policy" "warmup_scheduler_invoke" {
  name = "${var.function_name}-warmup-invoke"
  role = data.aws_iam_role.warmup_scheduler.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["lambda:InvokeFunction"]
      Resource = aws_lambda_function.this.arn
    }]
  })
}

# Same schedule as the deployed function: warm-up payload, one-day retry window.
resource "aws_scheduler_schedule" "warmup" {
  name                = "${var.function_name}-warmup"
  group_name          = "default"
  description         = "Warm up ${var.function_name}."
  schedule_expression = var.warmup_schedule_expression
  state               = "ENABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.this.arn
    role_arn = data.aws_iam_role.warmup_scheduler.arn
    input = jsonencode({
      warmup = true
    })

    retry_policy {
      maximum_event_age_in_seconds = 86400
      maximum_retry_attempts       = 185
    }
  }

  depends_on = [aws_iam_role_policy.warmup_scheduler_invoke]
}
