variable "function_name" {
  type    = string
  default = "SNOW_btsgsd"
}

variable "source_file" {
  description = "Path to the canonical lambda_function_snow_btsgsd.py metadata source."
  type        = string

  validation {
    condition     = fileexists(var.source_file)
    error_message = "The SNOW Lambda metadata source file must exist."
  }
}

variable "reserved_concurrent_executions" {
  description = "Optional positive integer reservation. Null omits the setting and uses shared account concurrency."
  type        = number
  default     = null

  validation {
    condition     = var.reserved_concurrent_executions == null ? true : var.reserved_concurrent_executions >= 1 && floor(var.reserved_concurrent_executions) == var.reserved_concurrent_executions
    error_message = "Use null for shared concurrency or a positive integer reservation; zero disables invocations and is not supported by this module."
  }
}

variable "environment_variables" {
  description = "Optional SN_INSTANCE and SN_SECRET_NAME values; unset values use the handler's Not Set defaults."
  type        = map(string)
  default     = {}
}

variable "log_retention_days" {
  type    = number
  default = 90
}

variable "common_tags" {
  type    = map(string)
  default = {}
}
