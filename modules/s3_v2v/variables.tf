variable "app_name" {
  description = "Application name used for bucket names."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9_-]{1,26}$", var.app_name))
    error_message = "app_name must be 2-27 characters and contain only letters, numbers, hyphens, or underscores."
  }
}

variable "v2v_root_prefix" {
  description = "S3 object prefix that CloudFront serves as the V2V application root."
  type        = string

  validation {
    condition     = var.v2v_root_prefix == "" || (!startswith(var.v2v_root_prefix, "/") && length(regexall("//", var.v2v_root_prefix)) == 0)
    error_message = "v2v_root_prefix must be empty or a relative S3 prefix without a leading slash or double slashes."
  }
}

variable "deploy_v2v_assets" {
  description = "Whether Terraform uploads files from v2v_dist_path to the hosting bucket."
  type        = bool
  default     = false
}

variable "force_destroy_buckets" {
  description = "Whether S3 buckets can be destroyed even when they contain objects."
  type        = bool
  default     = false
}

variable "noncurrent_version_expiration_days" {
  description = "Number of days to retain noncurrent versions of V2V application objects."
  type        = number
  default     = 30

  validation {
    condition     = var.noncurrent_version_expiration_days >= 1
    error_message = "noncurrent_version_expiration_days must be at least 1."
  }
}

variable "log_expiration_days" {
  description = "Number of days to retain current CloudFront log objects."
  type        = number
  default     = 365

  validation {
    condition     = var.log_expiration_days >= 1
    error_message = "log_expiration_days must be at least 1."
  }
}

variable "noncurrent_log_version_expiration_days" {
  description = "Number of days to retain noncurrent versions of CloudFront log objects."
  type        = number
  default     = 30

  validation {
    condition     = var.noncurrent_log_version_expiration_days >= 1
    error_message = "noncurrent_log_version_expiration_days must be at least 1."
  }
}

variable "v2v_dist_path" {
  description = "Path to the built Vite V2V app dist directory."
  type        = string
  default     = null
}

variable "frontend_config" {
  description = "Configuration object written to frontend-config.js."
  type        = map(string)
}

variable "common_tags" {
  description = "Common tags applied to supported resources."
  type        = map(string)
  default     = {}
}
