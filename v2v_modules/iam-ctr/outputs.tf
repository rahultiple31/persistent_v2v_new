output "policy_arn" {
  description = "ARN of the shared CTR reporting IAM policy."
  value       = aws_iam_policy.ctr.arn
}
