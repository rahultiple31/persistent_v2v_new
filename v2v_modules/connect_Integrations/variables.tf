variable "stack_name" {
  type = string
}

variable "display_name" {
  type = string
}

variable "connect_instance_arn" {
  type = string
}

variable "gateway_id" {
  description = "Actual generated Gateway ID, not the gateway display name."
  type        = string
}

variable "gateway_url" {
  description = "Existing AgentCore gateway MCP endpoint."
  type        = string
}

variable "common_tags" {
  type    = map(string)
  default = {}
}
