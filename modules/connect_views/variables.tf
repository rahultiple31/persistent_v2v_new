variable "connect_instance_arn" {
  description = "Amazon Connect instance ARN in which to create the view."
  type        = string

  validation {
    condition = can(regex(
      "^arn:[^:]+:connect:[^:]+:[0-9]{12}:instance/[0-9a-fA-F-]{36}$",
      var.connect_instance_arn
    ))
    error_message = "Provide a valid Amazon Connect instance ARN."
  }
}

variable "stack_name" {
  description = "CloudFormation stack name for the Connect view."
  type        = string
}

variable "view_name" {
  description = "Customer-managed view display name."
  type        = string
  default     = "Customer Details"
}

variable "view_template" {
  description = "View layout JSON with Head and Body; Connect generates its input schema."
  type        = string

  validation {
    condition = (
      can(jsondecode(var.view_template).Head) &&
      can(jsondecode(var.view_template).Body)
    )
    error_message = "Supply a view layout template containing Head and Body, rather than an input schema."
  }
}

variable "common_tags" {
  description = "Tags applied to the stack and view."
  type        = map(string)
  default     = {}
}
