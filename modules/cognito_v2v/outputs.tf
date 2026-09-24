output "identity_pool_id" {
  description = "Cognito Identity Pool ID."
  value       = aws_cognito_identity_pool.this.id
}

output "user_pool_id" {
  description = "Cognito User Pool ID."
  value       = aws_cognito_user_pool.this.id
}

output "user_pool_web_client_id" {
  description = "Cognito User Pool app client ID for the V2V application."
  value       = aws_cognito_user_pool_client.web.id
}

output "cognito_domain_url" {
  description = "Cognito hosted UI domain URL."
  value       = "https://${aws_cognito_user_pool_domain.this.domain}.auth.${data.aws_region.current.name}.amazoncognito.com"
}
