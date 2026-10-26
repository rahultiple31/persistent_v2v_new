################################################################################
# ECR Module — Outputs
################################################################################

output "repository_url" {
  description = "Full ECR repository URL (used as container image base URI in ECS task definition)."
  value       = aws_ecr_repository.proxy.repository_url
}

output "repository_name" {
  description = "Name of the ECR repository."
  value       = aws_ecr_repository.proxy.name
}

output "repository_arn" {
  description = "ARN of the ECR repository."
  value       = aws_ecr_repository.proxy.arn
}
