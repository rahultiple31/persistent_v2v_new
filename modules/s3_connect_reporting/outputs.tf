output "bucket_name" {
  value = aws_s3_bucket.reporting.bucket
}

output "bucket_arn" {
  value = aws_s3_bucket.reporting.arn
}
