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
  })
}
