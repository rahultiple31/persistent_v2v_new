output "authenticated_role_arn" {
  description = "IAM role ARN for authenticated Cognito identities."
  value       = aws_iam_role.authenticated.arn
}

output "unauthenticated_role_arn" {
  description = "IAM role ARN for unauthenticated Cognito identities."
  value       = aws_iam_role.unauthenticated.arn
}

output "translation_policy_attached" {
  description = "Whether browser identities have direct AWS translation permissions."
  value       = length(aws_iam_role_policy.authenticated) > 0
}
