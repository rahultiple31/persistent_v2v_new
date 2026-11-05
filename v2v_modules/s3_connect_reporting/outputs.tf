output "kms_key_arn" {
  description = "KMS key ARN used for reporting bucket default encryption."
  value       = module.encryption.kms_key_arn
}

output "kms_key_id" {
  description = "KMS key ID used for reporting bucket default encryption."
  value       = module.encryption.kms_key_id
}

output "kms_alias" {
  description = "Alias of the reporting bucket's default encryption key."
  value       = module.encryption.kms_alias
}
