################################################################################
# Root Outputs — mirrors CDK CfnOutput blocks
################################################################################

output "site_url" {
  description = "URL of the agent portal."
  value       = local.site_origin
}

output "load_balancer_dns_name" {
  description = "Internal DNS name of the Application Load Balancer."
  value       = module.alb.alb_dns_name
}

output "proxy_log_group_name" {
  description = "CloudWatch log group that receives all proxy JSON log lines."
  value       = module.cloudwatch.log_group_name
}

output "ecr_repository_url" {
  description = "ECR repository URL. Tag and push the proxy image here before the first apply."
  value       = module.ecr.repository_url
}

output "force_backup_parameter_name" {
  description = "SSM parameter name for the forceBackupTranslation switch."
  value       = module.ssm.force_backup_parameter_name
}

output "task_role_arn" {
  description = "ARN of the ECS task IAM role."
  value       = module.iam.task_role_arn
}

output "ecs_cluster_name" {
  description = "Name of the ECS cluster."
  value       = module.ecs.cluster_name
}

output "ecs_service_name" {
  description = "Name of the Fargate service."
  value       = module.ecs.service_name
}
