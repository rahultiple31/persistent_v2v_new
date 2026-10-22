variable "instance_arn" {
  type = string
}

variable "expected_instance_arn" {
  description = "Expected ARN resolved from the selected Connect instance alias."
  type        = string
  default     = null
}

variable "flow_json" {
  description = "Complete contact flow JSON."
  type        = string
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
  })
}

variable "tags" {
  type    = map(string)
  default = {}
}
