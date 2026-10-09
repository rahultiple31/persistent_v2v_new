variable "function_name" {
  type    = string
  default = "btsgsd-dev-us-east-1-CTR-Survey"
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
  description = "Python source file relative to this module directory."
  type        = string
  default     = "./src/lambda_function.py"
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

variable "environment_variables" {
  type = map(string)
  default = {
    S3_BUCKET           = "btsgsd-dev-us-east-1-connect-reporting-bucket"
    BUSINESS_TIMEZONE   = "America/Chicago"
    S3_PREFIX           = "connect/daily-interactions"
    CONNECT_INSTANCE_ID = "0cc3e955-8cdd-4a82-b6fe-7593e1674ffa"
    LOG_LEVEL           = "INFO"
  }
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
  default     = "UTC"
}

variable "common_tags" {
  type    = map(string)
  default = {}
}
