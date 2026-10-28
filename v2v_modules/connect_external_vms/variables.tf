variable "instance_name" {
  type    = string
  default = "btsgsd-dev-v2v-poc-us-east-1"
}

variable "external_vm_name" {
  type    = string
  default = "External VMs"
}

variable "external_vm_phone_number" {
  description = "External voicemail destination in E.164 format."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^\\+[1-9][0-9]{1,14}$", var.external_vm_phone_number))
    error_message = "Use an E.164 destination number, such as +18557117965."
  }
}
