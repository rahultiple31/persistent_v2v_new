variable "app_name" {
  description = "Application name used for Cognito resource names."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9_-]{1,48}$", var.app_name))
    error_message = "app_name must be 2-49 characters and contain only letters, numbers, hyphens, or underscores."
  }
}

variable "frontend_client_name" {
  description = "Cognito User Pool app client name for the V2V application."
  type        = string
}

variable "cognito_domain_prefix" {
  description = "Globally unique Cognito hosted UI domain prefix. Must not contain aws, amazon, or cognito."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$", var.cognito_domain_prefix)) && length(regexall("(aws|amazon|cognito)", var.cognito_domain_prefix)) == 0
    error_message = "cognito_domain_prefix must be 1-63 lowercase letters, numbers, or hyphens, start/end alphanumeric, and not contain aws, amazon, or cognito."
  }
}

variable "callback_urls" {
  description = "Cognito callback URLs."
  type        = list(string)

  validation {
    condition     = length(var.callback_urls) > 0 && alltrue([for url in var.callback_urls : can(regex("^https://", url))])
    error_message = "callback_urls must contain at least one HTTPS URL."
  }
}

variable "logout_urls" {
  description = "Cognito logout URLs."
  type        = list(string)

  validation {
    condition     = length(var.logout_urls) > 0 && alltrue([for url in var.logout_urls : can(regex("^https://", url))])
    error_message = "logout_urls must contain at least one HTTPS URL."
  }
}

variable "common_tags" {
  description = "Common tags applied to supported resources."
  type        = map(string)
  default     = {}
}
