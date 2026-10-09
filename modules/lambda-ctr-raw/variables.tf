variable "function_name" {
  type    = string
  default = "btsgsd-dev-us-east-1-CTR-Raw"
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
  default = 183
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
    OUTPUT_FILE_NAME  = "test.csv"
    S3_BUCKET         = "btsgsd-dev-us-east-1-connect-reporting-bucket"
    BUSINESS_TIMEZONE = "America/Chicago"
    S3_PREFIX         = "connect/daily-interactions"
    LOG_LEVEL         = "INFO"
  }
}

variable "log_retention_days" {
  type    = number
  default = 90
}

variable "common_tags" {
  type    = map(string)
  default = {}
}
