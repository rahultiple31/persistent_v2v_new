output "v2v_bucket_name" {
  description = "S3 bucket that stores the V2V application assets."
  value       = aws_s3_bucket.v2v.bucket
}

output "v2v_bucket_arn" {
  description = "S3 V2V application bucket ARN."
  value       = aws_s3_bucket.v2v.arn
}

output "v2v_bucket_regional_domain_name" {
  description = "Regional domain name for the V2V application bucket."
  value       = aws_s3_bucket.v2v.bucket_regional_domain_name
}

output "v2v_log_bucket_name" {
  description = "S3 bucket that stores CloudFront access logs."
  value       = aws_s3_bucket.v2v_logs.bucket
}

output "v2v_log_bucket_domain_name" {
  description = "Domain name for the CloudFront log bucket."
  value       = aws_s3_bucket.v2v_logs.bucket_domain_name
}

output "v2v_logs_acl_id" {
  description = "CloudFront log bucket ACL resource ID."
  value       = aws_s3_bucket_acl.v2v_logs.id
}
