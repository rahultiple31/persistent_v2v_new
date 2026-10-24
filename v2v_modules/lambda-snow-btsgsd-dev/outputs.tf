output "deployment" {
  description = "Function and published-version identifiers. Invoke VersionArn to use SnapStart."
  value = {
    FunctionName = aws_lambda_function.snow.function_name
    FunctionArn  = aws_lambda_function.snow.arn
    VersionArn   = aws_lambda_function.snow.qualified_arn
    Version      = aws_lambda_function.snow.version
  }
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.snow.name
}

output "execution_role_arn" {
  value = data.aws_iam_role.execution.arn
}
