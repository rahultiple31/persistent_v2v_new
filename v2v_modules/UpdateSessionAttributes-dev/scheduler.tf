# Reuse the existing Scheduler execution role.
data "aws_iam_role" "warmup_scheduler" {
  name = "BTSGSD-IVA-Lambda-Warmup-Scheduler-Role"
}

# Allow the existing role to invoke this Lambda.
resource "aws_iam_role_policy" "warmup_scheduler_invoke" {
  name = "BTSGSD-V2V-US-UpdateSessionAttributes-warmup-invoke"
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

resource "aws_scheduler_schedule" "warmup" {
  name                = "BTSGSD-V2V-US-UpdateSessionAttributes-warmup"
  group_name          = "default"
  description         = "Warm up BTSGSD-V2V-US-UpdateSessionAttributes every five minutes."
  schedule_expression = "rate(5 minutes)"
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
