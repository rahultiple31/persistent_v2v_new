output "authenticated_role_arn" {
  description = "IAM role ARN for authenticated Cognito identities."
  value       = aws_iam_role.authenticated.arn
}

output "unauthenticated_role_arn" {
  description = "IAM role ARN for unauthenticated Cognito identities."
  value       = aws_iam_role.unauthenticated.arn
}
