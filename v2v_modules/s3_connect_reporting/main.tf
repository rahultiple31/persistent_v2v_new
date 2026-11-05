data "aws_default_tags" "current" {}

resource "aws_s3_bucket" "reporting" {
  bucket = var.bucket_name
  tags   = data.aws_default_tags.current.tags
}

module "encryption" {
  source = "../s3_bucket_encryption"

  bucket_name = aws_s3_bucket.reporting.id
  tags        = data.aws_default_tags.current.tags
}

moved {
  from = aws_s3_bucket_server_side_encryption_configuration.reporting
  to   = module.encryption.aws_s3_bucket_server_side_encryption_configuration.this
}
