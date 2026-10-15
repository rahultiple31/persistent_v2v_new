# Tool names are case-sensitive and must match the gateway.
locals {
  tool_configurations = [
    for name in sort(tolist(var.tool_names)) : {
      ToolName = name
      ToolType = "MODEL_CONTEXT_PROTOCOL"
      ToolId   = "gateway_${var.namespace}__${name}"
    }
  ]
}
