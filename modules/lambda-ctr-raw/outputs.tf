output "function_name" {
  value = aws_lambda_function.raw.function_name
}

output "function_arn" {
  value = aws_lambda_function.raw.arn
}

output "invoke_arn" {
  value = aws_lambda_function.raw.invoke_arn
}

output "execution_role_arn" {
  value = aws_iam_role.execution.arn
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.raw.name
}
