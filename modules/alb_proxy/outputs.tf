output "internal_alb_dns_name" {
  description = "Internal ALB DNS name."
  value       = aws_lb.proxy.dns_name
}

output "internal_alb_arn" {
  description = "Internal ALB ARN."
  value       = aws_lb.proxy.arn
}

output "load_balancer_arn_suffix" {
  description = "Internal ALB ARN suffix used by CloudWatch metrics."
  value       = aws_lb.proxy.arn_suffix
}

output "target_group_arn" {
  description = "Proxy target group ARN."
  value       = aws_lb_target_group.proxy.arn

  depends_on = [aws_lb_listener.http]
}

output "target_group_arn_suffix" {
  description = "Proxy target group ARN suffix used by CloudWatch metrics."
  value       = aws_lb_target_group.proxy.arn_suffix
}
