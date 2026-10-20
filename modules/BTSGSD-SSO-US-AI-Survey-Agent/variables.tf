variable "assistant_id" {
  description = "Existing Connect assistant ID associated with the instance."
  type        = string
}

variable "orchestration_prompt_id" {
  description = "Existing published orchestration prompt ID, formatted as UUID:version."
  type        = string
}

variable "connect_instance_arn" {
  description = "ARN of the existing Connect instance."
  type        = string
}
