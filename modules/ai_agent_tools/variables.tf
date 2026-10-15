variable "namespace" {
  description = "Registered AgentCore gateway ID."
  type        = string
}

variable "tool_names" {
  description = "Exact MCP tool names exposed by the gateway."
  type        = set(string)
}
