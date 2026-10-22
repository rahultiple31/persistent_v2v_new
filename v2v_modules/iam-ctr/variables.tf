variable "policy_name" {
  description = "Name of the shared CTR reporting IAM policy."
  type        = string
}

variable "role_names" {
  description = "Existing Lambda execution roles to attach the reporting policy to."
  type        = set(string)
}

variable "s3_object_arn" {
  description = "S3 object ARN pattern allowed for CTR reporting writes."
  type        = string
}
