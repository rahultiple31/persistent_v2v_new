output "function_name" {
  value = aws_lambda_function.export.function_name
}

output "function_arn" {
  value = aws_lambda_function.export.arn
}

output "invoke_arn" {
  value = aws_lambda_function.export.invoke_arn
}

output "execution_role_arn" {
  value = aws_iam_role.execution["lambda"].arn
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.export.name
}

output "scheduler_arn" {
  value = aws_scheduler_schedule.daily_export.arn
}
