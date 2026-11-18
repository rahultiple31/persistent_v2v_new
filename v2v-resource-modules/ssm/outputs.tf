################################################################################
# SSM Module — Outputs
################################################################################

output "force_backup_parameter_name" {
  description = "Parameter Store name for the forceBackupTranslation switch."
  value       = aws_ssm_parameter.force_backup_translation.name
}

output "force_backup_parameter_arn" {
  description = "Parameter Store ARN for the forceBackupTranslation switch (used in IAM policy)."
  value       = aws_ssm_parameter.force_backup_translation.arn
}

output "prompt_versions_parameter_name" {
  description = "Parameter Store name of the approved interpreter prompt versions."
  value       = aws_ssm_parameter.prompt_versions.name
}

output "prompt_versions_parameter_arn" {
  description = "Parameter Store ARN of the approved interpreter prompt versions (used in IAM policy)."
  value       = aws_ssm_parameter.prompt_versions.arn
}

output "prompt_parameter_prefix" {
  description = "Name prefix of the interpreter prompts (SecureString, created by hand): <prefix><language>."
  value       = "${var.ssm_hierarchy}prompts/"
}

output "bedrock_region_parameter_name" {
  description = "Parameter Store name for the bedrockRegion record."
  value       = aws_ssm_parameter.bedrock_region.name
}
