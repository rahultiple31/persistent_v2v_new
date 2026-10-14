variable "stack_name" {
  type = string
}

variable "gateway_name" {
  type = string
}

variable "role_name" {
  type = string
}

variable "lambda_arn" {
  type = string
}

variable "connect_url" {
  type = string
}

variable "gateway_id_audience" {
  description = "Generated Gateway ID used as the second allowed JWT audience."
  type        = string
  default     = null

  validation {
    condition = var.gateway_id_audience == null ? true : can(
      regex("^([0-9a-z][-]?){1,100}-[a-z0-9]{10}$", var.gateway_id_audience)
    )
    error_message = "Use the actual generated Gateway ID."
  }
}

variable "common_tags" {
  type    = map(string)
  default = {}
}
