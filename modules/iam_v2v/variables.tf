variable "name_prefix" {
  description = "Name prefix for IAM roles and policies."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9+=,.@_-]{1,48}$", var.name_prefix))
    error_message = "name_prefix must be 1-48 IAM name-safe characters: letters, numbers, +=,.@_ or hyphen."
  }
}

variable "identity_pool_id" {
  description = "Cognito Identity Pool ID used in role trust policies."
  type        = string
}

variable "common_tags" {
  description = "Common tags applied to supported resources."
  type        = map(string)
  default     = {}
}
