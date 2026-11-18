terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.100.0, < 7.0.0"
    }
    awscc = {
      source  = "hashicorp/awscc"
      version = "~> 1.0"
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

# Reads the system voice agent's prompt template and locale (read-only).
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

  # Retrieve, Complete and Escalate are exact copies of the dev
  # btsgsd-SupportAgent v43 tools (assets/tools/*.json, API field names). Only
  # Retrieve's two dev-only IDs are replaced: the assistant, and the assistant
  # association with the shared knowledge base.
  mirrored_tool_names = ["Retrieve", "Complete", "Escalate"]
  mirrored_tools = [
    for name in local.mirrored_tool_names : jsondecode(replace(
      replace(
        file("${path.module}/assets/tools/${lower(name)}.json"),
        "\"__ASSISTANT_ID__\"",
        jsonencode(var.assistant_id)
      ),
      "\"__ASSISTANT_ASSOCIATION_IDS__\"",
      jsonencode(jsonencode([awscc_wisdom_assistant_association.knowledge_base.assistant_association_id]))
    ))
  ]

  # Dev order: the MCP gateway tools first, then Retrieve, Complete, Escalate.
  # Schemas are passed as JSON text so numbers and booleans keep their types.
  tool_configurations = concat(
    [
      for tool in var.tool_configurations : {
        tool_name                      = tool.ToolName
        tool_type                      = tool.ToolType
        tool_id                        = tool.ToolId
        title                          = null
        description                    = null
        instruction                    = null
        input_schema                   = null
        output_schema                  = null
        annotations                    = null
        override_input_values          = null
        output_filters                 = null
        user_interaction_configuration = null
      }
    ],
    [
      for tool in local.mirrored_tools : {
        tool_name   = tool.toolName
        tool_type   = tool.toolType
        tool_id     = try(tool.toolId, null)
        title       = try(tool.title, null)
        description = try(tool.description, null)
        # The API drops empty examples and annotations when it stores the agent
        # (dev exports them as [] and {}); send them only when non-empty, so
        # plans don't show a permanent diff.
        instruction = try({
          instruction = tool.instruction.instruction
          examples    = length(try(tool.instruction.examples, [])) > 0 ? tolist(tool.instruction.examples) : null
        }, null)
        input_schema  = try(jsonencode(tool.inputSchema), null)
        output_schema = try(jsonencode(tool.outputSchema), null)
        annotations   = length(try(tool.annotations, {})) > 0 ? jsonencode(tool.annotations) : null
        override_input_values = try([
          for override in tool.overrideInputValues : {
            json_path = override.jsonPath
            value = {
              constant = {
                type  = override.value.constant.type
                value = override.value.constant.value
              }
            }
          }
        ], null)
        output_filters = null
        user_interaction_configuration = try({
          is_user_confirmation_required = tool.userInteractionConfiguration.isUserConfirmationRequired
        }, null)
      }
    ]
  )
}

# The dev Retrieve tool searches btsgsd-knowledgebase through its assistant
# association; the V2V assistant gets its own association with the same base.
resource "awscc_wisdom_assistant_association" "knowledge_base" {
  assistant_id     = var.assistant_id
  association_type = "KNOWLEDGE_BASE"
  association = {
    knowledge_base_id = var.knowledge_base_id
  }
  tags = [for key, value in local.tags : { key = key, value = value }]
}

resource "awscc_wisdom_ai_prompt" "support" {
  assistant_id  = var.assistant_id
  name          = var.prompt_name
  description   = try(local.custom_prompt.description, "Dev customer-service orchestration prompt.")
  type          = "ORCHESTRATION"
  api_format    = "MESSAGES"
  template_type = "TEXT"
  model_id      = var.prompt_model_id
  tags          = local.tags

  template_configuration = {
    text_full_ai_prompt_edit_template_configuration = {
      text = local.prompt_text
    }
  }

  lifecycle {
    precondition {
      condition     = length(local.system_prompt) <= 100000
      error_message = "Generated system prompt has ${length(local.system_prompt)} characters; QConnect allows at most 100000. Shorten ${var.prompt_yaml_file}, or use a complete system: | prompt instead of appending prompt: | instructions to the source."
    }
  }
}

# A new prompt version is published whenever the prompt changes.
resource "awscc_wisdom_ai_prompt_version" "support" {
  assistant_id          = var.assistant_id
  ai_prompt_id          = awscc_wisdom_ai_prompt.support.ai_prompt_id
  modified_time_seconds = awscc_wisdom_ai_prompt.support.modified_time_seconds

  lifecycle {
    create_before_destroy = true
  }
}

resource "awscc_wisdom_ai_agent" "support" {
  assistant_id = var.assistant_id
  name         = var.agent_name
  description  = "Support orchestration agent copied from ${var.source_agent_name}."
  type         = "ORCHESTRATION"
  tags         = local.tags

  configuration = {
    orchestration_ai_agent_configuration = {
      connect_instance_arn          = var.connect_instance_arn
      locale                        = try(local.source_configuration.Locale, null)
      orchestration_ai_guardrail_id = try(local.source_configuration.OrchestrationAIGuardrailId, null)
      orchestration_ai_prompt_id    = awscc_wisdom_ai_prompt_version.support.ai_prompt_version_id
      tool_configurations           = local.tool_configurations
    }
  }

  lifecycle {
    precondition {
      condition     = length(local.mirrored_tools) == 3 && alltrue([for index, tool in local.mirrored_tools : tool.toolName == local.mirrored_tool_names[index]])
      error_message = "assets/tools must hold the Retrieve, Complete and Escalate tool definitions."
    }
    precondition {
      condition     = !anytrue([for tool in var.tool_configurations : contains([for name in local.mirrored_tool_names : lower(name)], lower(tool.ToolName))])
      error_message = "tool_configurations must not redefine Retrieve, Complete or Escalate; they come from assets/tools."
    }
  }
}

# A new agent version is published whenever the agent changes; flows use it.
resource "awscc_wisdom_ai_agent_version" "support" {
  assistant_id          = var.assistant_id
  ai_agent_id           = awscc_wisdom_ai_agent.support.ai_agent_id
  modified_time_seconds = awscc_wisdom_ai_agent.support.modified_time_seconds

  lifecycle {
    create_before_destroy = true
  }
}

locals {
  # The agent ARN may carry a :$LATEST qualifier; versions append their number.
  agent_arn            = trimsuffix(awscc_wisdom_ai_agent.support.ai_agent_arn, ":$LATEST")
  agent_version_number = format("%d", awscc_wisdom_ai_agent_version.support.version_number)
  agent_version_arn    = "${local.agent_arn}:${local.agent_version_number}"
}
