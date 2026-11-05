output "kms_key_arn" {
  description = "KMS key ARN used as the bucket's default encryption key ID."
  value       = aws_kms_key.this.arn
}

output "kms_key_id" {
  description = "KMS key ID for the bucket's default encryption key."
  value       = aws_kms_key.this.key_id
}

output "kms_alias" {
  description = "Alias of the bucket's default encryption key."
  value       = aws_kms_alias.this.name
}
