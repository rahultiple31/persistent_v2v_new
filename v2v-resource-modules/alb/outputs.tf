################################################################################
# ALB Module — Outputs
################################################################################

output "alb_arn" {
  description = "ARN of the Application Load Balancer."
  value       = aws_lb.main.arn
}

output "alb_dns_name" {
  description = "Internal DNS name of the ALB (used for Route 53 alias record)."
  value       = aws_lb.main.dns_name
}

output "alb_zone_id" {
  description = "Hosted-zone ID of the ALB (used for Route 53 alias record)."
  value       = aws_lb.main.zone_id
}

output "target_group_arn" {
  description = "ARN of the proxy target group."
  value       = aws_lb_target_group.proxy.arn
}

output "alb_log_bucket_name" {
  description = "Name of the S3 bucket that receives ALB access logs."
  value       = aws_s3_bucket.alb_logs.id
}
