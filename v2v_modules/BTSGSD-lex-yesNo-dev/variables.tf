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

variable "layer_arn" {
  description = "OpenTelemetry layer version ARN."
  type        = string
}

variable "environment_variables" {
  description = "Lambda environment variables."
  type        = map(string)
  default     = {}
}

variable "lex_bot_alias_arn" {
  description = "Optional Lex V2 bot alias ARN allowed to invoke the function."
  type        = string
  default     = null

  validation {
    condition = (
      var.lex_bot_alias_arn == null ||
      can(regex(
        "^arn:[^:]+:lex:[^:]+:[0-9]{12}:bot-alias/[^/]+/[^/]+$",
        var.lex_bot_alias_arn
      ))
    )
    error_message = "Provide a valid Lex V2 bot alias ARN or null."
  }
}

variable "common_tags" {
  description = "Common resource tags."
  type        = map(string)
  default     = {}
}
