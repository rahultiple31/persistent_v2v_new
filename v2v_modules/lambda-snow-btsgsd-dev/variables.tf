variable "function_name" {
  type    = string
  default = "BTSGSD-V2V-US-SNOW"
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

variable "connect_instance_arn" {
  description = "V2V Connect instance allowed to invoke the Lambda."
  type        = string
  validation {
    condition     = can(regex("^arn:[^:]+:connect:[^:]+:[0-9]{12}:instance/[0-9a-f-]{36}$", var.connect_instance_arn))
    error_message = "connect_instance_arn must be a Connect instance ARN."
  }
}

variable "ai_agent_source_arn" {
  description = "AI agent ARN, wildcards allowed, granted invoke through Bedrock AgentCore (the V2V assistant's agents)."
  type        = string
  validation {
    condition     = can(regex("^arn:[^:]+:wisdom:[^:]+:[0-9]{12}:ai-agent/[0-9a-f-]{36}/", var.ai_agent_source_arn))
    error_message = "ai_agent_source_arn must be an AI agent ARN on a Q in Connect assistant."
  }
}
