output "parameter_names" {
  description = "Created SSM parameter names."
  value       = { for key, parameter in aws_ssm_parameter.this : key => parameter.name }
}
