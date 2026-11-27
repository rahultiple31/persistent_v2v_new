output "security_group_id" {
  description = "ID of the Lambda internet security group."
  value       = aws_security_group.lambda_internet.id
}
