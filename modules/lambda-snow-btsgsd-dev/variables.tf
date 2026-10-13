variable "function_name" {
  type    = string
  default = "SNOW_btsgsd-dev"
}

variable "reserved_concurrency" {
  description = "Reserved concurrent executions for the function, or null for no reservation (uses the unreserved account pool and skips the capacity check)."
  type        = number
  default     = 300
  nullable    = true

  validation {
    condition     = var.reserved_concurrency == null ? true : var.reserved_concurrency >= 1 && floor(var.reserved_concurrency) == var.reserved_concurrency
    error_message = "reserved_concurrency must be a positive whole number or null; 0 would throttle every invocation."
  }
}

variable "environment_variables" {
  description = "Optional SN_INSTANCE and SN_SECRET_NAME values; omitted values use the supplied handler defaults."
  type        = map(string)
  default     = {}
}

variable "python_executable" {
  description = "Python executable for the read-only concurrency check, which also requires AWS CLI."
  type        = string
  default     = "python3"
}

variable "log_retention_days" {
  type    = number
  default = 90
}

variable "common_tags" {
  type    = map(string)
  default = {}
}
