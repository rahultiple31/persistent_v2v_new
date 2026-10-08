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
        can(regex("^[A-Za-z0-9_+=,.@-]{1,64}$", name)) &&
        !startswith(upper(name), "REPLACE_WITH_")
      ])
    )
    error_message = "Set connect_reporting_lambda_role_names to three distinct existing Lambda execution role names in the deployment account. Placeholder values and role ARNs are not allowed."
  }
}

variable "common_tags" {
  type    = map(string)
  default = {}
}
