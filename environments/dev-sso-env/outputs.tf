output "lambda_internet_security_group_id" {
  description = "ID of the security group for Lambda HTTPS access to ServiceNow."
  value       = module.lambda_internet_security_group.security_group_id
}
