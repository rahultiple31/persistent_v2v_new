output "ecr_repository_url" {
  description = "ECR repository URL used by the proxy CICD pipeline."
  value       = aws_ecr_repository.proxy.repository_url
}
