locals {
  admin_mcp_configuration = var.admin_mcp_access == null ? null : {
    connect_instance_arn = var.connect_instance_arn
    aws_profile          = var.aws_profile
    namespace            = var.admin_mcp_access.namespace

    tool_names = [
      for tool in var.tool_configurations :
      trimprefix(tool.ToolId, "gateway_${var.admin_mcp_access.namespace}__")
      if tool.ToolType == "MODEL_CONTEXT_PROTOCOL"
    ]

    agent_arns = [
      aws_cloudformation_stack.agent.outputs["AgentArn"],
      aws_cloudformation_stack.agent.outputs["AgentVersionArn"],
    ]
  }
}

resource "terraform_data" "admin_mcp_access" {
  count = var.admin_mcp_access == null ? 0 : 1

  input = local.admin_mcp_configuration

  triggers_replace = {
    configuration = jsonencode(local.admin_mcp_configuration)
    script_hash   = filesha256("${path.module}/grant_admin_mcp_tools.py")
    python        = var.python_executable
  }

  provisioner "local-exec" {
    command = "\"${var.python_executable}\" \"${abspath("${path.module}/grant_admin_mcp_tools.py")}\""

    environment = {
      SUPPORT_AGENT_ADMIN_ACCESS = jsonencode(self.input)
      AWS_PAGER                  = ""
      AWS_CLI_AUTO_PROMPT        = "off"
    }
  }
}
