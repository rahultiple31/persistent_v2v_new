################################################################################
# Networking Module — Outputs
################################################################################

output "alb_security_group_id" {
  description = "Security group ID attached to the Application Load Balancer."
  value       = aws_security_group.alb.id
}

output "service_security_group_id" {
  description = "Security group ID attached to the Fargate proxy tasks."
  value       = aws_security_group.service.id
}

output "endpoint_security_group_id" {
  description = "Security group ID attached to all VPC interface endpoints."
  value       = aws_security_group.endpoint.id
}

output "vpc_endpoint_ids" {
  description = "Map of endpoint logical name to VPC endpoint ID."
  value       = { for k, ep in aws_vpc_endpoint.interface : k => ep.id }
}
