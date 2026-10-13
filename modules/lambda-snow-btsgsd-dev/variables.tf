variable "function_name" {
  type    = string
  default = "SNOW_btsgsd-dev"
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
