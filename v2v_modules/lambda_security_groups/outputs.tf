output "endpoint_security_group_id" {
  description = "Security group ID for Lambda interface endpoints."
  value       = aws_security_group.endpoint.id
}

output "core_security_group_id" {
  description = "Security group ID for Connect Lambdas."
  value       = aws_security_group.core.id
}
