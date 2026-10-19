variable "connect_instance_arn" {
  description = "Existing Amazon Connect instance ARN."
  type        = string
}

variable "view_name" {
  description = "Amazon Connect view name."
  type        = string
  default     = "Customer Details"
}

variable "view_template" {
  description = "JSON view layout containing Head and Body, loaded with file()."
  type        = string

  validation {
    condition = (
      can(jsondecode(var.view_template).Head) &&
      can(jsondecode(var.view_template).Body)
    )
    error_message = "view_template must be a JSON view layout containing Head and Body."
  }
}

variable "common_tags" {
  description = "Tags applied to the view."
  type        = map(string)
  default     = {}
}
