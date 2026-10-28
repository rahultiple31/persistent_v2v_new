variable "function_name" {
  type    = string
  default = "BTSGSD-V2V-US-CTR-Survey"
}

variable "runtime" {
  type    = string
  default = "python3.13"
}

variable "handler" {
  type    = string
  default = "lambda_function_ctr_.lambda_handler"
}

variable "source_file" {
  description = "Absolute source path, or null to use the module's CTR Survey source."
  type        = string
  default     = null
}

variable "architectures" {
  type    = list(string)
  default = ["x86_64"]
}

variable "memory_size" {
  type    = number
  default = 1024
}

variable "timeout" {
  type    = number
  default = 183
}

variable "connect_instance_alias" {
  description = "Existing Amazon Connect instance alias."
  type        = string
  default     = "btsgsd-dev-v2v-poc-us-east-1"
}

variable "environment_variables" {
  type = map(string)
  default = {
    S3_BUCKET         = "btsgsd-v2v-us-connect-reporting-bucket"
    BUSINESS_TIMEZONE = "America/Chicago"
    S3_PREFIX         = "connect/daily-interactions"
    LOG_LEVEL         = "INFO"
  }
}

variable "log_retention_days" {
  type    = number
  default = 90
}

variable "scheduler_name" {
  type    = string
  default = "BTSGSD-V2V-US-ACD-Survey-Daily-Export"
}

variable "schedule_expression" {
  type    = string
  default = "cron(0 1 * * ? *)"
}

variable "schedule_timezone" {
  description = "Scheduler timezone, independent of BUSINESS_TIMEZONE."
  type        = string
  default     = "UTC"
}

variable "common_tags" {
  type    = map(string)
  default = {}
}
