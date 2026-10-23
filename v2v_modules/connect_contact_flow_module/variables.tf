variable "instance_arn" {
  description = "Target Amazon Connect instance ARN."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^arn:aws:connect:[a-z0-9-]+:[0-9]{12}:instance/[0-9a-f-]+$", var.instance_arn))
    error_message = "Provide a valid Amazon Connect instance ARN."
  }
}

variable "name" {
  description = "Contact flow module name."
  type        = string
}

variable "content_file" {
  description = "Path to the supplied contact flow module JSON."
  type        = string
}

variable "voicemail_queue_arn" {
  description = "Existing voicemail queue ARN in the target Connect instance."
  type        = string
  nullable    = false
}

variable "beep_prompt_arn" {
  description = "Existing Beep.wav prompt ARN in the target Connect instance."
  type        = string
  nullable    = false
}

variable "survey_data_table_id" {
  description = "Connect survey data-table ID containing voicemail messages."
  type        = string
  nullable    = false
}

variable "timestamper_lambda_arn" {
  description = "Existing unqualified Lambda ARN returning vmx3_timestamp."
  type        = string
  nullable    = false

  validation {
    condition = can(regex(
      "^arn:aws:lambda:[a-z0-9-]+:[0-9]{12}:function:[A-Za-z0-9_-]+$",
      var.timestamper_lambda_arn
    ))
    error_message = "Provide an unqualified timestamper Lambda function ARN."
  }
}

variable "tags" {
  type    = map(string)
  default = {}
}
