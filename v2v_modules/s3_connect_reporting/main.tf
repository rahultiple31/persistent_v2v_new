data "aws_default_tags" "current" {}

resource "aws_s3_bucket" "reporting" {
  bucket = var.bucket_name
  tags   = data.aws_default_tags.current.tags
}

resource "aws_s3_bucket_server_side_encryption_configuration" "reporting" {
  bucket = aws_s3_bucket.reporting.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}
