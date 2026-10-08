variable "bucket_name" {
  description = "S3 bucket for Amazon Connect reporting."
  type        = string
}

variable "lambda_role_names" {
  description = "Existing execution role names for the three reporting Lambdas."
  type        = set(string)

  validation {
    condition = (
      length(var.lambda_role_names) == 3 &&
      alltrue([
        for name in var.lambda_role_names :
        can(regex("^[A-Za-z0-9_+=,.@-]{1,64}$", name))
      ])
    )
    error_message = "Provide three distinct IAM role names, not role ARNs."
  }
}

variable "common_tags" {
  type    = map(string)
  default = {}
}
