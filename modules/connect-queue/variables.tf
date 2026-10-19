variable "instance_alias" {
  description = "Existing Amazon Connect instance alias."
  type        = string
}

variable "queue_name" {
  description = "Name of the queue to create."
  type        = string
}

variable "outbound_phone_number_id" {
  description = "Connect resource UUID for +18557113853, already claimed and associated with the instance."
  type        = string
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
