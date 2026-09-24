variable "project_name" {
  description = "Project prefix used for names and tags."
  type        = string
}

variable "environment" {
  description = "Environment name."
  type        = string
}

variable "aws_region" {
  description = "AWS region for this module instance."
  type        = string
}

variable "region_code" {
  description = "Business region code for resource names and tags."
  type        = string
}

variable "common_tags" {
  description = "Common tags applied to resources."
  type        = map(string)
}

variable "name_prefix" {
  description = "Optional resource name prefix override."
  type        = string
  default     = null

  validation {
    condition     = var.name_prefix == null || can(regex("^[A-Za-z0-9][A-Za-z0-9_-]{0,47}$", var.name_prefix))
    error_message = "name_prefix must be 1-48 characters and contain only letters, numbers, hyphens, or underscores."
  }
}

variable "lambda_name_suffix" {
  description = "Suffix used in the Lambda function name."
  type        = string
  default     = "lambda-test"
}

variable "runtime" {
  description = "Lambda runtime for the disposable pipeline test function."
  type        = string
  default     = "python3.12"

  validation {
    condition     = startswith(var.runtime, "python")
    error_message = "runtime must be a Python runtime because the module packages Python source."
  }
}

variable "timeout" {
  description = "Lambda timeout in seconds."
  type        = number
  default     = 10

  validation {
    condition     = var.timeout >= 1 && var.timeout <= 900
    error_message = "timeout must be between 1 and 900 seconds."
  }
}

variable "memory_size" {
  description = "Lambda memory size in MB."
  type        = number
  default     = 128

  validation {
    condition     = var.memory_size >= 128 && var.memory_size <= 10240
    error_message = "memory_size must be between 128 and 10240 MB."
  }
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention in days for the Lambda log group."
  type        = number
  default     = 30

  validation {
    condition = contains([
      1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180,
      365, 400, 545, 731, 1096, 1827, 2192, 2557,
      2922, 3288, 3653
    ], var.log_retention_days)
    error_message = "log_retention_days must be a CloudWatch Logs supported retention value."
  }
}
