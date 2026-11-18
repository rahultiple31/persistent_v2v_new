variable "instance_arn" {
  type = string
}

variable "expected_instance_arn" {
  description = "Expected ARN resolved from the selected Connect instance alias."
  type        = string
  default     = null
}

variable "latam_queue_name" {
  type    = string
  default = "BTSGSD-DEV-SSO-LATAM-MAIN-QUEUE"
}

variable "phone_lookup_function_name" {
  type    = string
  default = "SNOW_Abbvie"
}

variable "flow_dependencies" {
  type = object({
    us_queue_arn                  = string
    customer_queue_flow_arn       = string
    survey_flow_arn               = string
    agent_ui_flow_arn             = string
    language_table_id             = string
    survey_table_id               = string
    blocker_table_id              = string
    session_attributes_lambda_arn = string
    silence_guard_lambda_arn      = string
    queue_metrics_lambda_arn      = string
    # V2V Q in Connect assistant, SupportAgent version and IT Support Lex alias
    # (replace the dev ones in the exported flow).
    ai_assistant_arn         = string
    ai_agent_version_arn     = string
    it_support_bot_alias_arn = string
  })

  validation {
    condition = (
      can(regex("^arn:[^:]+:wisdom:[^:]+:[0-9]{12}:assistant/[0-9a-f-]{36}$", var.flow_dependencies.ai_assistant_arn)) &&
      can(regex("^arn:[^:]+:wisdom:[^:]+:[0-9]{12}:ai-agent/[0-9a-f-]{36}/[0-9a-f-]{36}:[0-9]+$", var.flow_dependencies.ai_agent_version_arn)) &&
      can(regex("^arn:[^:]+:lex:[^:]+:[0-9]{12}:bot-alias/[A-Za-z0-9]+/[A-Za-z0-9]+$", var.flow_dependencies.it_support_bot_alias_arn)) &&
      startswith(var.flow_dependencies.ai_agent_version_arn, replace(var.flow_dependencies.ai_assistant_arn, ":assistant/", ":ai-agent/"))
    )
    error_message = "Provide the V2V assistant ARN, a version-qualified AI agent ARN on that assistant, and a Lex bot alias ARN."
  }
}

variable "tags" {
  type    = map(string)
  default = {}
}
