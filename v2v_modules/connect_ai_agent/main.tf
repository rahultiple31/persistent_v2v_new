terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.100.0, < 7.0.0"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
  }
}

data "aws_region" "current" {}
data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

data "external" "source" {
  program = [var.python_executable, "${path.module}/read_source.py"]

  query = {
    assistant_id         = var.assistant_id
    connect_instance_arn = var.connect_instance_arn
    account_id           = data.aws_caller_identity.current.account_id
    region               = data.aws_region.current.region
    aws_profile          = var.aws_profile
    source_name          = var.source_agent_name
    source_prompt_name   = var.source_prompt_name == null ? "" : var.source_prompt_name
    model_id             = var.prompt_model_id
  }
}

locals {
  custom_prompt        = yamldecode(file(var.prompt_yaml_file))
  source_configuration = jsondecode(data.external.source.result.configuration)
  source_prompt        = yamldecode(data.external.source.result.prompt_text)
  complete_tool_configuration = {
    ToolName    = "Complete"
    ToolType    = "RETURN_TO_CONTROL"
    Description = "Close conversation when customer has no more questions"
    InputSchema = jsondecode(file("${path.module}/assets/complete-input-schema.json"))
    Instruction = {
      Instruction = "Call Complete ONLY in the same response as the spoken closing message that the system prompt defines for the current outcome. The system prompt decides whether to ask \"anything else\" first; never ask it on your own. Never call Complete without spoken text."
    }
  }
  escalate_tool_configuration = {
    ToolName    = "Escalate"
    ToolType    = "RETURN_TO_CONTROL"
    Description = "Escalate to human agent when customer issue can not solve."
    InputSchema = jsondecode(file("${path.module}/assets/escalate-input-schema.json"))
    Instruction = {
      Instruction = "Call Escalate ONLY when the system prompt defines a transfer for the current outcome, in the same response as that outcome's spoken transfer line (LATAM Veeva/Medcom: no line, the flow plays it). Do not escalate for unclear answers, silence, a wrong UPI, unverified callers or a failed knowledge search; the system prompt defines those paths."
    }
  }
  retrieve_instruction = <<-EOT
    Use only for a finalized support need when the orchestration prompt permits retrieval.
    Never retrieve for greetings, silence, yes/no answers, UPI availability, UPI capture,
    UPI readback confirmation, or first-name verification. A clear Yes to UPI availability
    must continue to UPI capture without retrieval. Retrieval failure never authorizes
    Complete or Escalate; follow the prompt's failure handling.
  EOT
  source_tools_with_retrieve_instruction = [
    for tool in try(local.source_configuration.ToolConfigurations, []) :
    merge(tool, var.override_retrieve_instruction && lower(try(tool.ToolName, "")) == "retrieve" ? {
      Instruction = merge(try(tool.Instruction, {}), {
        Instruction = trimspace(local.retrieve_instruction)
      })
    } : {})
  ]
  # Version IDs are strings; extracting their suffix keeps CloudFormation outputs string-valued.
  agent_version_id = { "Fn::GetAtt" = ["SupportAgentVersion", "AIAgentVersionId"] }
  agent_version_number = {
    "Fn::Select" = [1, { "Fn::Split" = [":", local.agent_version_id] }]
  }
  prompt_version_id = { "Fn::GetAtt" = ["SupportPromptVersion", "AIPromptVersionId"] }
  prompt_version_number = {
    "Fn::Select" = [1, { "Fn::Split" = [":", local.prompt_version_id] }]
  }
  tags = merge(var.tags, {
    Platform   = "Amazon Connect AI Agent"
    CopiedFrom = var.source_agent_name
  })

  # A system field supplies a complete prompt; a prompt field extends the source policy.
  # Keep runtime tool definitions available without duplicating a full source system prompt.
  custom_instructions = trimspace(try(local.custom_prompt.system, local.custom_prompt.prompt))
  system_prompt = can(local.custom_prompt.system) ? join("\n\n", compact([
    local.custom_instructions,
    strcontains(local.custom_instructions, "{{$.toolConfigurationList}}") ? "" : "<toolConfigurationList>\n{{$.toolConfigurationList}}\n</toolConfigurationList>"
  ])) : <<-SYSTEM
      ${local.source_prompt.system}

      <customer_service_policy>
      ${local.custom_instructions}
      </customer_service_policy>
    SYSTEM
  prompt_messages = try(local.custom_prompt.messages, local.source_prompt.messages)

  # Preserve runtime messages and source template fields; exclude custom test metadata.
  prompt_text = yamlencode(merge(local.source_prompt, {
    system = local.system_prompt

    # Claude Sonnet 5 rejects a final assistant message prefill.
    messages = [
      for index, message in local.prompt_messages : message
      if !(index == length(local.prompt_messages) - 1 && try(message.role == "assistant", false))
    ]
  }))

  template = jsonencode({
    AWSTemplateFormatVersion = "2010-09-09"
    Resources = {
      SupportPrompt = {
        Type = "AWS::Wisdom::AIPrompt"
        Properties = {
          AssistantId  = var.assistant_id
          Name         = var.prompt_name
          Description  = try(local.custom_prompt.description, "Dev customer-service orchestration prompt.")
          Type         = "ORCHESTRATION"
          ApiFormat    = "MESSAGES"
          TemplateType = "TEXT"
          ModelId      = var.prompt_model_id
          Tags         = local.tags
          TemplateConfiguration = {
            TextFullAIPromptEditTemplateConfiguration = {
              Text = local.prompt_text
            }
          }
        }
      }
      SupportPromptVersion = {
        Type = "AWS::Wisdom::AIPromptVersion"
        Properties = {
          AssistantId         = var.assistant_id
          AIPromptId          = { "Fn::GetAtt" = ["SupportPrompt", "AIPromptId"] }
          ModifiedTimeSeconds = { "Fn::GetAtt" = ["SupportPrompt", "ModifiedTimeSeconds"] }
        }
      }
      SupportAgent = {
        Type = "AWS::Wisdom::AIAgent"
        Properties = {
          AssistantId = var.assistant_id
          Name        = var.agent_name
          Description = "Support orchestration agent copied from ${var.source_agent_name}."
          Type        = "ORCHESTRATION"
          Tags        = local.tags
          Configuration = {
            OrchestrationAIAgentConfiguration = merge(local.source_configuration, {
              ConnectInstanceArn      = var.connect_instance_arn
              OrchestrationAIPromptId = local.prompt_version_id

              # Preserve built-in tools, replacing requested terminal tools by name.
              ToolConfigurations = concat(
                [
                  for tool in local.source_tools_with_retrieve_instruction : tool
                  if !contains(
                    [for added in var.tool_configurations : added.ToolId],
                    try(tool.ToolId, "")
                  ) && !(
                    var.include_complete_tool &&
                    lower(try(tool.ToolName, "")) == "complete"
                  ) && !(
                    var.include_escalate_tool &&
                    lower(try(tool.ToolName, "")) == "escalate"
                  )
                ],
                var.tool_configurations,
                var.include_complete_tool ? [local.complete_tool_configuration] : [],
                var.include_escalate_tool ? [local.escalate_tool_configuration] : []
              )
            })
          }
        }
      }
      SupportAgentVersion = {
        Type = "AWS::Wisdom::AIAgentVersion"
        Properties = {
          AssistantId         = var.assistant_id
          AIAgentId           = { "Fn::GetAtt" = ["SupportAgent", "AIAgentId"] }
          ModifiedTimeSeconds = { "Fn::GetAtt" = ["SupportAgent", "ModifiedTimeSeconds"] }
        }
      }
    }
    Outputs = {
      AssistantId        = { Value = var.assistant_id }
      ConnectInstanceArn = { Value = var.connect_instance_arn }
      SourceAgentId      = { Value = data.external.source.result.source_agent_id }
      AgentId            = { Value = { "Fn::GetAtt" = ["SupportAgent", "AIAgentId"] } }
      AgentArn           = { Value = { "Fn::GetAtt" = ["SupportAgent", "AIAgentArn"] } }
      AgentVersion       = { Value = local.agent_version_number }
      AgentVersionId     = { Value = local.agent_version_id }
      AgentVersionArn = {
        Value = {
          "Fn::Sub" = ["$${AgentArn}:$${AgentVersion}", {
            AgentArn     = { "Fn::GetAtt" = ["SupportAgent", "AIAgentArn"] }
            AgentVersion = local.agent_version_number
          }]
        }
      }
      PromptId      = { Value = { "Fn::GetAtt" = ["SupportPrompt", "AIPromptId"] } }
      PromptVersion = { Value = local.prompt_version_number }
    }
  })
}

resource "aws_s3_object" "template" {
  bucket                 = var.template_bucket_name
  key                    = "ai-agents/${var.agent_name}/${sha256(local.template)}.json"
  content                = local.template
  content_type           = "application/json"
  server_side_encryption = "AES256"
  tags                   = local.tags

  lifecycle {
    create_before_destroy = true

    precondition {
      condition     = length(local.system_prompt) <= 100000
      error_message = "Generated system prompt has ${length(local.system_prompt)} characters; QConnect allows at most 100000. Shorten ${var.prompt_yaml_file}, or use a complete system: | prompt instead of appending prompt: | instructions to the source."
    }

    precondition {
      condition = !var.override_retrieve_instruction || length([
        for tool in try(local.source_configuration.ToolConfigurations, []) : tool
        if lower(try(tool.ToolName, "")) == "retrieve"
      ]) == 1
      error_message = "Expected exactly one Retrieve tool on the source Amazon Connect AI agent."
    }
  }
}

resource "aws_cloudformation_stack" "agent" {
  name = var.stack_name
  tags = local.tags
  template_url = format(
    "https://s3.%s.%s/%s/%s",
    data.aws_region.current.region,
    data.aws_partition.current.dns_suffix,
    aws_s3_object.template.bucket,
    aws_s3_object.template.key
  )
}
