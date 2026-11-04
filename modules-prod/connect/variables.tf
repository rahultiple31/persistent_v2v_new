variable "project_name" {
  description = "Project prefix used for names and tags."
  type        = string
}

variable "environment" {
  description = "Environment name."
  type        = string
}

variable "aws_region" {
  description = "AWS region for this module instance."
  type        = string
}

variable "region_code" {
  description = "Business region code, for example us, europe, or apac."
  type        = string
}

variable "common_tags" {
  description = "Common tags applied to resources."
  type        = map(string)
}

variable "contact_center_alias" {
  description = "Base alias for Amazon Connect instances."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9_-]*$", var.contact_center_alias))
    error_message = "contact_center_alias must start with a letter or number and contain only letters, numbers, hyphens, or underscores."
  }
}

variable "service_name_suffix" {
  description = "Suffix used in the Amazon Connect instance alias."
  type        = string
  default     = "connect"

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9_-]*$", var.service_name_suffix))
    error_message = "service_name_suffix must start with a letter or number and contain only letters, numbers, hyphens, or underscores."
  }
}

variable "admin_user_enabled" {
  description = "Whether to create an initial Amazon Connect administrator user."
  type        = bool
  default     = false

  validation {
    condition = !var.admin_user_enabled || alltrue([
      var.admin_user_first_name != null,
      var.admin_user_last_name != null,
      var.admin_user_username != null,
      var.admin_user_email != null
    ])
    error_message = "When admin_user_enabled is true, all admin user fields must be provided."
  }
}

variable "admin_user_first_name" {
  description = "First name for the Amazon Connect administrator user."
  type        = string
  default     = null

  validation {
    condition     = var.admin_user_first_name == null ? true : length(var.admin_user_first_name) >= 1 && length(var.admin_user_first_name) <= 100
    error_message = "admin_user_first_name must contain 1-100 characters."
  }
}

variable "admin_user_last_name" {
  description = "Last name for the Amazon Connect administrator user."
  type        = string
  default     = null

  validation {
    condition     = var.admin_user_last_name == null ? true : length(var.admin_user_last_name) >= 1 && length(var.admin_user_last_name) <= 100
    error_message = "admin_user_last_name must contain 1-100 characters."
  }
}

variable "admin_user_username" {
  description = "Case-sensitive SAML username for the Amazon Connect administrator; it must match the IdP RoleSessionName."
  type        = string
  default     = null

  validation {
    condition     = var.admin_user_username == null || can(regex("^[A-Za-z0-9_.@-]{1,64}$", var.admin_user_username))
    error_message = "admin_user_username must be 1-64 SAML-compatible characters: letters, numbers, underscore, hyphen, period, or @."
  }
}

variable "admin_user_email" {
  description = "Secondary notification email for the SAML Amazon Connect administrator."
  type        = string
  default     = null

  validation {
    condition     = var.admin_user_email == null || can(regex("^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,63}$", var.admin_user_email))
    error_message = "admin_user_email must be a valid email address."
  }
}

variable "customer_queue_flow_content" {
  description = "JSON content for the transfer-to-agent customer queue flow."
  type        = string
  default     = null
}

variable "outbound_whisper_flow_content" {
  description = "JSON content for the US outbound whisper flow."
  type        = string
  default     = null
}

variable "agent_transfer_flow_content" {
  description = "JSON content for the US agent-to-agent transfer flow."
  type        = string
  default     = null
}
