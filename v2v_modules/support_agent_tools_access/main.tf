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

variable "agent_stack_name" {
  type    = string
  default = "BTSGSD-V2V-US-SupportAgent"
}

# Resolve existing deployments; this module creates neither stack.
data "aws_cloudformation_stack" "gateway" {
  name = var.gateway_stack_name
}

data "aws_cloudformation_stack" "support_agent" {
  name = var.agent_stack_name
}

locals {
  grant_script = abspath("${path.module}/../connect_ai_agent/grant_admin_mcp_tools.py")

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
      "${data.aws_cloudformation_stack.support_agent.outputs["AgentArn"]}:$LATEST",
      data.aws_cloudformation_stack.support_agent.outputs["AgentVersionArn"],
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
      condition     = data.aws_cloudformation_stack.support_agent.outputs["ConnectInstanceArn"] == var.connect_instance_arn
      error_message = "The existing support-agent stack must belong to the selected V2V Connect instance."
    }
  }
}
