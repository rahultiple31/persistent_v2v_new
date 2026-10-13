output "deployment" {
  description = "Function and published-version identifiers. Invoke VersionArn to use SnapStart."
  value       = aws_cloudformation_stack.snow.outputs
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.snow.name
}

output "execution_role_arn" {
  value = aws_iam_role.execution.arn
}
