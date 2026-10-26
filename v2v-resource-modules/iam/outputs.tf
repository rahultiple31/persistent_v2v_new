################################################################################
# IAM Module — Outputs
################################################################################

output "task_role_arn" {
  description = "ARN of the ECS task IAM role (runtime AWS API calls)."
  value       = aws_iam_role.task.arn
}

output "task_role_name" {
  description = "Name of the ECS task IAM role."
  value       = aws_iam_role.task.name
}

output "execution_role_arn" {
  description = "ARN of the ECS task execution role (ECR pull + CloudWatch Logs)."
  value       = aws_iam_role.task_execution.arn
}

output "execution_role_name" {
  description = "Name of the ECS task execution role."
  value       = aws_iam_role.task_execution.name
}
