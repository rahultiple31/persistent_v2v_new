variable "ssm_hierarchy" {
  description = "SSM Parameter Store hierarchy used by the V2V solution."
  type        = string

  validation {
    condition     = startswith(var.ssm_hierarchy, "/") && length(regexall("//", var.ssm_hierarchy)) == 0
    error_message = "ssm_hierarchy must start with / and must not contain double slashes."
  }
}

variable "parameters" {
  description = "SSM string parameters to create under ssm_hierarchy."
  type        = map(string)
}

variable "common_tags" {
  description = "Common tags applied to supported resources."
  type        = map(string)
  default     = {}
}
