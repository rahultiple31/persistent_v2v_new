terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.100.0, < 7.0.0"
    }
  }
}

variable "connect_instance_arn" {
  description = "Existing V2V Connect instance ARN."
  type        = string
}

variable "python_executable" {
  type    = string
  default = "python3"
}

variable "gateway_stack_name" {
  type    = string
  default = "BTSGSD-V2V-US-AgentCore-DefaultGateway"
}

variable "support_agent" {
  description = "The Terraform-managed SupportAgent (module.btsgsd_support_agent outputs)."
  type = object({
    agent_arn            = string
    agent_version_arn    = string
    connect_instance_arn = string
  })
}

# Resolve the existing gateway stack; the agent comes from module.btsgsd_support_agent.
data "aws_cloudformation_stack" "gateway" {
  name = var.gateway_stack_name
}


locals {
  grant_script = abspath("${path.module}/../connect_ai_agent/grant_admin_mcp_tools.py")

  # Strip any :$LATEST qualifier; the version ARN comes from the published version.
  support_agent_arn = trimsuffix(var.support_agent.agent_arn, ":$LATEST")

  access_configuration = {
    connect_instance_arn = var.connect_instance_arn
    aws_profile          = ""
    namespace            = data.aws_cloudformation_stack.gateway.outputs["GatewayId"]

    tool_names = [
      "BTSGSD-V2V-US-nexthink-handoff___handoff",
      "BTSGSD-V2V-US-snow-interaction___Interaction__Interaction",
      "BTSGSD-V2V-US-snow-userlookup___UserLookUp___UserLookUp",
    ]

    agent_arns = [
      local.support_agent_arn,
      var.support_agent.agent_version_arn,
    ]
  }
}

resource "terraform_data" "admin_mcp_access" {
  input = local.access_configuration

  triggers_replace = {
    configuration = jsonencode(local.access_configuration)
    script_hash   = filesha256(local.grant_script)
    python        = var.python_executable
  }

  provisioner "local-exec" {
    command = "\"${var.python_executable}\" \"${local.grant_script}\""

    environment = {
      SUPPORT_AGENT_ADMIN_ACCESS = jsonencode(self.input)
      AWS_PAGER                  = ""
      AWS_CLI_AUTO_PROMPT        = "off"
    }
  }

  lifecycle {
    precondition {
      condition     = var.support_agent.connect_instance_arn == var.connect_instance_arn
      error_message = "The SupportAgent must belong to the selected V2V Connect instance."
    }
  }
}
