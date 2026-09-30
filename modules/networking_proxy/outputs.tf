output "vpc_id" {
  description = "Proxy VPC ID."
  value       = aws_vpc.proxy.id
}

output "private_subnet_ids" {
  description = "Private subnet IDs used by the ALB and ECS service."
  value       = aws_subnet.private[*].id
}

output "nat_gateway_id" {
  description = "NAT gateway ID used by proxy alarms."
  value       = aws_nat_gateway.proxy.id
}

output "selected_availability_zones" {
  description = "Availability Zones selected for the proxy network."
  value       = local.selected_availability_zones
}
