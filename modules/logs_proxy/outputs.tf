output "proxy_log_group_name" {
  description = "CloudWatch log group for proxy container logs."
  value       = aws_cloudwatch_log_group.proxy.name
}

output "vpc_flow_log_group_name" {
  description = "CloudWatch log group for VPC flow logs."
  value       = aws_cloudwatch_log_group.flow_logs.name
}
