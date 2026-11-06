variable "settings" {
  description = "Target instance, tags, and dependencies for this module-owned flow export."
  type = object({
    instance_arn                     = string
    expected_instance_arn            = optional(string)
    tags                             = optional(map(string), {})
    dependency_names                 = optional(map(string), {})
    python_executable                = optional(string, "python3")
    survey_data_table_id             = optional(string)
    queue_metrics_lambda_arn         = optional(string)
    session_attributes_lambda_arn    = optional(string)
    timestamper_lambda_arn           = optional(string)
    transfer_customer_queue_flow_arn = optional(string)
    yesno_bot_alias_arn              = string
    voicemail_flow_module_id         = string
  })

  validation {
    condition = can(regex(
      "^arn:[^:]+:lex:[^:]+:[0-9]{12}:bot-alias/[A-Za-z0-9]+/[A-Za-z0-9]+$",
      var.settings.yesno_bot_alias_arn
    ))
    error_message = "Provide the deployed Yes/No Lex V2 bot alias ARN. Deploy lex_yesno_bot first if its state output is missing."
  }
}
