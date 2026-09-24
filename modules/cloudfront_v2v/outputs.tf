output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID for the V2V application."
  value       = aws_cloudfront_distribution.v2v.id
}

output "cloudfront_distribution_arn" {
  description = "CloudFront distribution ARN for the V2V application."
  value       = aws_cloudfront_distribution.v2v.arn
}

output "cloudfront_distribution_domain_name" {
  description = "CloudFront distribution domain name."
  value       = aws_cloudfront_distribution.v2v.domain_name
}

output "v2v_url" {
  description = "Public HTTPS URL for the V2V application."
  value       = "https://${aws_cloudfront_distribution.v2v.domain_name}"
}
