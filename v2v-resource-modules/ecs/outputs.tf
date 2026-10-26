################################################################################
# ECS Module — Outputs
################################################################################

output "cluster_name" {
  description = "Name of the ECS cluster."
  value       = aws_ecs_cluster.main.name
}

output "cluster_arn" {
  description = "ARN of the ECS cluster."
  value       = aws_ecs_cluster.main.arn
}

output "service_name" {
  description = "Name of the Fargate proxy service."
  value       = aws_ecs_service.proxy.name
}

output "service_id" {
  description = "Full ARN of the Fargate proxy service."
  value       = aws_ecs_service.proxy.id
}

output "task_definition_arn" {
  description = "ARN (including revision) of the active task definition."
  value       = aws_ecs_task_definition.proxy.arn
}
