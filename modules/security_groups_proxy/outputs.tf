output "alb_security_group_id" {
  description = "Security group ID for the internal ALB."
  value       = aws_security_group.alb.id
}

output "service_security_group_id" {
  description = "Security group ID for the ECS service."
  value       = aws_security_group.service.id
}
