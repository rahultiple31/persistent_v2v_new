# Normalize agent-facing names; preserve exact gateway names and case in ToolId.
locals {
  tool_configurations = [
    for name in sort(tolist(var.tool_names)) : {
      ToolName = lower(replace(name, "/[^A-Za-z0-9]+/", "_"))
      ToolType = "MODEL_CONTEXT_PROTOCOL"
      ToolId   = "gateway_${var.namespace}__${name}"
    }
  ]
}
