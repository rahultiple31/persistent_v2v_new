variable "connect_instance_arn" {
  description = "Target Amazon Connect instance ARN."
  type        = string

  validation {
    condition = can(regex(
      "^arn:[^:]+:connect:[^:]+:[0-9]{12}:instance/[0-9a-fA-F-]{36}$",
      var.connect_instance_arn
    ))
    error_message = "Provide a valid Amazon Connect instance ARN."
  }
}

variable "customer_details_view_arn" {
  description = "Existing Customer Details View ARN, including its version."
  type        = string
}

variable "flow_content" {
  description = "Contact flow JSON containing the view ARN placeholder."
  type        = string

  validation {
    condition = (
      can(jsondecode(var.flow_content).StartAction) &&
      can(jsondecode(var.flow_content).Actions) &&
      strcontains(var.flow_content, "__CUSTOMER_DETAILS_VIEW_ARN__")
    )
    error_message = "Supply complete flow JSON containing StartAction, Actions, and __CUSTOMER_DETAILS_VIEW_ARN__."
  }
}

variable "common_tags" {
  description = "Tags applied to the contact flow."
  type        = map(string)
  default     = {}
}
