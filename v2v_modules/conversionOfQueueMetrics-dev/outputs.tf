output "lambda_name" {
  value = aws_lambda_function.lambda.function_name
}

output "lambda_arn" {
  value = aws_lambda_function.lambda.arn
}

output "iam_role_arn" {
  value = data.aws_iam_role.lambda_role.arn
}
