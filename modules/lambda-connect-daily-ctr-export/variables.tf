variable "function_name" {
  type    = string
  default = "btsgsd-dev-us-east-1-connect-daily-ctr-export"
}

variable "runtime" {
  type    = string
  default = "python3.13"
}

variable "handler" {
  type    = string
  default = "lambda_function.lambda_handler"
}

variable "source_file" {
  description = "Absolute path to the Python source file."
  type        = string
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
  default = 60
}

variable "ephemeral_storage_size" {
  type    = number
  default = 512
}

variable "connect_instance_alias" {
  description = "Existing Amazon Connect instance alias."
  type        = string
  default     = "btsgsd-dev-us-east-1"
}

variable "environment_variables" {
  type = map(string)
  default = {
    S3_BUCKET             = "btsgsd-dev-us-east-1-connect-reporting-bucket"
    BUSINESS_TIMEZONE     = "America/Chicago"
    S3_PREFIX             = "connect/daily-interactions"
    FILE_PREFIX           = "abbvieacd"
    LOG_LEVEL             = "INFO"
    OUTPUT_DELIMITER      = ","
    SHORT_ABANDON_SECONDS = "10"
  }
}

variable "log_group_name" {
  type    = string
  default = "/aws/lambda/btsgsd-connect-inatnces-daily-ctr-export"
}

variable "log_retention_days" {
  type    = number
  default = 90
}

variable "scheduler_name" {
  type    = string
  default = "btsgsd-dev-us-east-1-ACD-Daily-Export"
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
