output "function_name" {
  value = aws_cloudformation_stack.lambda.outputs["FunctionName"]
}

output "function_arn" {
  value = aws_cloudformation_stack.lambda.outputs["FunctionArn"]
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.this.name
}
