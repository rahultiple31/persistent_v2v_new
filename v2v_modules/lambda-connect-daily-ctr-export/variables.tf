variable "function_name" {
  type    = string
  default = "BTSGSD-V2V-US-connect-daily-ctr-export"
}

variable "runtime" {
  type    = string
  default = "python3.14"
}

variable "handler" {
  type    = string
  default = "lambda_function.lambda_handler"
}

variable "source_file" {
  description = "Absolute source path, or null to use the module's daily CTR export source."
  type        = string
  default     = null
}

variable "architectures" {
  type    = list(string)
  default = ["arm64"]
}

variable "memory_size" {
  type    = number
  default = 2048
}

variable "timeout" {
  type    = number
  default = 900
}

variable "ephemeral_storage_size" {
  type    = number
  default = 4096
}

variable "connect_instance_alias" {
  description = "Existing Amazon Connect instance alias."
  type        = string
  default     = "btsgsd-dev-v2v-poc-us-east-1"
}

variable "environment_variables" {
  type = map(string)
  default = {
    BUSINESS_TIMEZONE     = "America/Chicago"
    FILE_PREFIX           = "abbvieacd"
    LOG_LEVEL             = "INFO"
    OUTPUT_DELIMITER      = ","
    SHORT_ABANDON_SECONDS = "10"
  }
}

variable "s3_bucket_name" {
  description = "Reporting bucket for this deployment."
  type        = string
  default     = "btsgsd-v2v-us-connect-reporting-bucket"
}

variable "deployment_area" {
  description = "Area used in the daily ACD S3 key prefix."
  type        = string
  default     = "NORAM"

  validation {
    condition     = contains(["NORAM", "APAC", "EMEA"], var.deployment_area)
    error_message = "deployment_area must be NORAM, APAC, or EMEA."
  }
}

variable "log_group_name" {
  type    = string
  default = "/aws/lambda/BTSGSD-V2V-US-connect-inatnces-daily-ctr-export"
}

variable "log_retention_days" {
  type    = number
  default = 90
}

variable "scheduler_name" {
  type    = string
  default = "btsgsd-dev-us-east-1-ACD-Survey-Daily-Export"
}

variable "schedule_expression" {
  type    = string
  default = "cron(0 1 * * ? *)"
}

variable "schedule_timezone" {
  description = "Scheduler timezone, independent of BUSINESS_TIMEZONE."
  type        = string
  default     = "America/Chicago"
}

variable "common_tags" {
  type    = map(string)
  default = {}
}
