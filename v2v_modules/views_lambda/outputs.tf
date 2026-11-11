output "function_name" {
  value = aws_lambda_function.this.function_name
}

output "function_arn" {
  value = aws_lambda_function.this.arn
}

output "role_arn" {
  value = aws_iam_role.execution.arn
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.this.name
}

output "warmup_schedule_name" {
  value = aws_scheduler_schedule.warmup.name
}
