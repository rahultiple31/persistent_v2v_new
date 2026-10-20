variable "assistant_id" {
  description = "Existing assistant UUID associated with the Connect instance."
  type        = string

  validation {
    condition     = can(regex("^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$", var.assistant_id))
    error_message = "assistant_id must be an assistant UUID."
  }
}

variable "connect_instance_arn" {
  description = "Existing Amazon Connect instance ARN."
  type        = string

  validation {
    condition     = can(regex("^arn:[a-z-]+:connect:[a-z0-9-]+:[0-9]{12}:instance/[a-f0-9-]+$", var.connect_instance_arn))
    error_message = "Provide a valid Amazon Connect instance ARN."
  }
}

variable "orchestration_prompt_id" {
  description = "Existing published orchestration prompt identifier: UUID:version."
  type        = string

  validation {
    condition     = can(regex("^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}:[1-9][0-9]*$", var.orchestration_prompt_id))
    error_message = "Provide a published prompt identifier in UUID:version format."
  }
}
