output "lambda_name" {
  value = aws_lambda_function.consolidation.function_name
}

output "scheduler_name" {
  value = aws_scheduler_schedule.consolidation.name
}
