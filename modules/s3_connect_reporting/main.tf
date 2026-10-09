resource "aws_s3_bucket" "reporting" {
  bucket = var.bucket_name
  tags   = var.common_tags
}
