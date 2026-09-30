output "ecs_cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.proxy.name
}

output "ecs_service_name" {
  description = "ECS service name."
  value       = aws_ecs_service.proxy.name
}
