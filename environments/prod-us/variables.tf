variable "aws_region" {
  description = "Default AWS region for the unaliased provider."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment name."
  type        = string
  default     = "prod"
}

variable "project_name" {
  description = "Project prefix used for names and tags."
  type        = string
  default     = "btsgsd"
}

variable "contact_center_alias" {
  description = "Alias prefix for the Amazon Connect production instances."
  type        = string
  default     = "connect"
}

variable "connect_name_suffix" {
  description = "Service tag value passed to the Connect module."
  type        = string
  default     = "connect"
}

variable "common_tags" {
  description = "Additional tags applied to all resources."
  type        = map(string)
  default     = {}
}

variable "connect_admin_user_enabled" {
  description = "Whether to create an initial Amazon Connect administrator user."
  type        = bool
  default     = false
}

variable "connect_admin_first_name" {
  description = "First name for the Amazon Connect administrator user."
  type        = string
  default     = null
}

variable "connect_admin_last_name" {
  description = "Last name for the Amazon Connect administrator user."
  type        = string
  default     = null
}

variable "connect_admin_username" {
  description = "Case-sensitive SAML username; it must match the IdP RoleSessionName."
  type        = string
  default     = null
}

variable "connect_admin_email" {
  description = "Secondary notification email for the SAML administrator."
  type        = string
  default     = null
}

variable "app_name" {
  description = "Application name used for tags."
  type        = string
  default     = "btsgsd-prod-us-east-1"
}
