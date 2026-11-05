# Object Lock requires versioning and cannot be disabled once enabled in AWS.
# No default retention period or legal hold is configured here.
resource "aws_s3_bucket_versioning" "this" {
  bucket = var.bucket_name

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_object_lock_configuration" "this" {
  bucket              = aws_s3_bucket_versioning.this.bucket
  object_lock_enabled = "Enabled"
}
