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

output "bedrock_region_parameter_name" {
  description = "Parameter Store name for the bedrockRegion record."
  value       = aws_ssm_parameter.bedrock_region.name
}
