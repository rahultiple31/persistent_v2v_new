variable "instance_alias" {
  description = "Existing Amazon Connect instance alias."
  type        = string
}

variable "queue_name" {
  description = "Name of the queue to create."
  type        = string
}

variable "outbound_phone_number_id" {
  description = "Phone-number UUID claimed by the selected Connect instance, or null to omit outbound caller configuration."
  type        = string
  default     = null
}

variable "outbound_flow_name" {
  description = "Existing outbound caller flow name."
  type        = string
  default     = "Default outbound"
}

variable "tags" {
  type = map(string)
  default = {
    Env = "Dev"
    Org = "btsgsd"
  }
}
