variable "alarm_name_suffix" {
  description = "Suffix that ends every alarm name (the console alarms end in -dev)."
  type        = string
  default     = "-v2v"
}

variable "topic_name" {
  description = "Name of the SNS topic the alarms notify."
  type        = string
}

variable "alert_email_addresses" {
  description = "Email addresses subscribed to the topic. Each address must confirm by email."
  type        = list(string)

  validation {
    condition     = alltrue([for address in var.alert_email_addresses : can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", address))])
    error_message = "Each alert email address must look like name@example.com."
  }
}

variable "connect_instance_alias" {
  description = "Alias of the Connect instance whose metrics are watched."
  type        = string
}

variable "gateway_stack_name" {
  description = "CloudFormation stack (module.agentcore_gateway) whose GatewayArn output identifies the AgentCore gateway."
  type        = string
}

variable "gateway_metric_dimensions" {
  description = "Dimensions added to Resource on the AgentCore alarms. The gateway publishes Latency, SystemErrors and Throttles only with Operation and Protocol set; {} watches Resource alone, as the console alarms do."
  type        = map(string)
  default = {
    Operation = "InvokeGateway"
    Protocol  = "MCP"
  }
}

variable "lambda_alarms" {
  description = "Lambdas to watch, keyed by function name. alarm_label is the name part of each alarm (suffix-only rename of the console alarms)."
  type = map(object({
    alarm_label = string
  }))
}

variable "contact_flow_alarms" {
  description = "Contact flows to watch, keyed by flow name, with the name part of each alarm."
  type = map(object({
    alarm_label = string
  }))
}

variable "queue_alarms" {
  description = "Standard queues to watch, keyed by queue name, with the name part of each alarm."
  type = map(object({
    alarm_label = string
  }))
}

variable "lambda_account_concurrency_limit" {
  description = "Account Lambda concurrency limit; the base of the concurrency alarm for functions without reserved concurrency."
  type        = number
  default     = 1000
}

variable "threshold_ratio" {
  description = "Share of a Lambda's timeout (Duration) or concurrency limit (ConcurrentExecutions) that raises the alarm."
  type        = number
  default     = 0.8

  validation {
    condition     = var.threshold_ratio > 0 && var.threshold_ratio < 1
    error_message = "threshold_ratio must be between 0 and 1."
  }
}

variable "tags" {
  description = "Tags for the topic and every alarm. Each alarm also gets its Priority tag."
  type        = map(string)
  default     = {}
}
