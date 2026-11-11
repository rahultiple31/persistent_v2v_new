resource "aws_scheduler_schedule" "daily_export" {
  name                         = var.scheduler_name
  schedule_expression          = var.schedule_expression
  schedule_expression_timezone = var.schedule_timezone

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.survey.arn
    role_arn = aws_iam_role.execution["scheduler"].arn
    input = jsonencode({
      scheduled_time = "<aws.scheduler.scheduled-time>"
    })
  }

  depends_on = [aws_iam_role_policy.scheduler_invoke]
}
