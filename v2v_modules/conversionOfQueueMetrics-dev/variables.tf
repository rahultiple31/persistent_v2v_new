variable "function_name" {
  description = "Lambda function name."
  type        = string
}

variable "iam_role_name" {
  description = "Existing Lambda execution role name."
  type        = string
}

variable "log_group_name" {
  description = "CloudWatch log group name."
  type        = string
}

variable "zip_path" {
  description = "Existing ZIP containing lambda_function.py at its root."
  type        = string
}

variable "environment_variables" {
  description = "Lambda environment variables, including TableName."
  type        = map(string)

  validation {
    condition     = try(length(trimspace(var.environment_variables["TableName"])) > 0, false)
    error_message = "environment_variables must contain a nonempty TableName."
  }
}

variable "common_tags" {
  description = "Common resource tags."
  type        = map(string)
  default     = {}
}
