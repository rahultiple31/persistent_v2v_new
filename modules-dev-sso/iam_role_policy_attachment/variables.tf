variable "role_arn" {
  description = "ARN of the existing IAM role to receive the managed policy."
  type        = string
}

variable "policy_arn" {
  description = "ARN of the managed IAM policy to attach."
  type        = string
}
