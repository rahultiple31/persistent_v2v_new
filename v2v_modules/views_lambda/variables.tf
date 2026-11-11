variable "function_name" {
  description = "Lambda function name, for example BTSGSD-V2V-US-views."
  type        = string
}

variable "connect_instance_arn" {
  description = "Amazon Connect instance that invokes the Lambda and that it reads contacts from."
  type        = string
}

variable "vpc_id" {
  description = "VPC that holds the Lambda subnets and the core security group."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets for the Lambda network interfaces."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) > 0
    error_message = "Provide at least one subnet ID."
  }
}

variable "security_group_ids" {
  description = "Security groups to attach in addition to the core Lambda security group."
  type        = list(string)
  default     = []
}

variable "core_security_group_name" {
  description = "Name of the existing core Lambda security group (created by the lambda_security_groups choice)."
  type        = string
}

variable "memory_size" {
  description = "Memory in MB. Matches the deployed function."
  type        = number
  default     = 256
}

variable "timeout" {
  description = "Timeout in seconds. Matches the deployed function; keep it above poll_sleep_seconds."
  type        = number
  default     = 10
}

variable "poll_sleep_seconds" {
  description = "Seconds the function waits before returning while a contact is still connecting (POLL_SLEEP)."
  type        = number
  default     = 4

  validation {
    condition     = var.poll_sleep_seconds >= 0 && var.poll_sleep_seconds < var.timeout
    error_message = "poll_sleep_seconds must be at least 0 and shorter than the Lambda timeout."
  }
}

variable "log_retention_days" {
  description = "Retention of the function's CloudWatch log group."
  type        = number
  default     = 14
}

variable "warmup_schedule_expression" {
  description = "EventBridge Scheduler expression for the warm-up invocation."
  type        = string
  default     = "rate(1 hour)"
}

variable "warmup_scheduler_role_name" {
  description = "Existing role that EventBridge Scheduler assumes to invoke Lambda warm-ups."
  type        = string
  default     = "BTSGSD-IVA-Lambda-Warmup-Scheduler-Role"
}

variable "common_tags" {
  description = "Tags applied to every resource that supports them."
  type        = map(string)
  default     = {}
}
