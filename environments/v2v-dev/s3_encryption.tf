# Encryption resources and the default KMS key are created inside the module.
module "dev_ai_template_encryption" {
  count  = local.dev_ai_template_bucket_enabled ? 1 : 0
  source = "../../v2v_modules/s3_bucket_encryption"

  providers = {
    aws = aws.us_east_1
  }

  bucket_name = aws_s3_bucket.dev_ai_template[count.index].id
  tags        = local.dev_ai_tags
}

# Keep ownership of the existing encryption configuration when moving it.
moved {
  from = aws_s3_bucket_server_side_encryption_configuration.dev_ai_template[0]
  to   = module.dev_ai_template_encryption[0].aws_s3_bucket_server_side_encryption_configuration.this
}

output "dev_ai_template_kms_key" {
  description = "Default encryption KMS key for the AI template bucket."
  value = try({
    id    = module.dev_ai_template_encryption[0].kms_key_id
    arn   = module.dev_ai_template_encryption[0].kms_key_arn
    alias = module.dev_ai_template_encryption[0].kms_alias
  }, null)
}

output "intent_kb_kms_key" {
  description = "Default encryption KMS key for the intent knowledge-base bucket."
  value = try({
    id    = module.s3_intent_kb[0].kms_key_id
    arn   = module.s3_intent_kb[0].kms_key_arn
    alias = module.s3_intent_kb[0].kms_alias
  }, null)
}
