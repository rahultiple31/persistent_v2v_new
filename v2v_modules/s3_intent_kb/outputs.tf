output "bucket_name" {
  value = aws_s3_bucket.this.bucket
}

output "bucket_arn" {
  value = aws_s3_bucket.this.arn
}

output "kms_key_arn" {
  value = module.encryption.kms_key_arn
}

output "kms_key_id" {
  value = module.encryption.kms_key_id
}

output "kms_alias" {
  value = module.encryption.kms_alias
}
