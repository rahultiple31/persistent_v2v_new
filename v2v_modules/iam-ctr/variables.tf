variable "policy_name" {
  description = "Name of the shared CTR reporting IAM policy."
  type        = string
  default     = "BTSGSD-V2V-US-ctr-reporting-policy"
}

variable "role_names" {
  description = "Existing Lambda execution roles to attach the reporting policy to."
  type        = set(string)
  default = [
    "BTSGSD-V2V-US-CTR-Survey-lambda-role",
    "BTSGSD-V2V-US-connect-daily-ctr-export-lambda-role",
    "BTSGSD-V2V-US-CTR-Raw-lambda-role",
  ]
}
