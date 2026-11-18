mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { name = "us-east-1" }
  }
  mock_data "aws_partition" {
    defaults = { dns_suffix = "amazonaws.com" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
}

mock_provider "awscc" {
  mock_resource "awscc_wisdom_assistant_association" {
    defaults = {
      assistant_association_id = "00000000-0000-0000-0000-0000000000aa"
    }
  }
  mock_resource "awscc_wisdom_ai_prompt" {
    defaults = {
      ai_prompt_id          = "00000000-0000-0000-0000-0000000000b1"
      modified_time_seconds = 1700000000
    }
  }
  mock_resource "awscc_wisdom_ai_prompt_version" {
    defaults = {
      ai_prompt_version_id = "00000000-0000-0000-0000-0000000000b1:3"
      version_number       = 3
    }
  }
  mock_resource "awscc_wisdom_ai_agent" {
    defaults = {
      ai_agent_id           = "00000000-0000-0000-0000-0000000000c1"
      ai_agent_arn          = "arn:aws:wisdom:us-east-1:123456789012:ai-agent/00000000-0000-0000-0000-000000000001/00000000-0000-0000-0000-0000000000c1"
      assistant_arn         = "arn:aws:wisdom:us-east-1:123456789012:assistant/00000000-0000-0000-0000-000000000001"
      modified_time_seconds = 1700000001
    }
  }
  mock_resource "awscc_wisdom_ai_agent_version" {
    defaults = {
      ai_agent_version_id = "00000000-0000-0000-0000-0000000000c1:7"
      version_number      = 7
    }
  }
}

mock_provider "external" {
  mock_data "external" {
    defaults = {
      result = {
        source_agent_id = "00000000-0000-0000-0000-000000000002"
        configuration   = <<-JSON
          {
            "Locale": "en_US",
            "OrchestrationAIPromptId": "00000000-0000-0000-0000-000000000004:1",
            "ToolConfigurations": [{
              "ToolName": "Retrieve",
              "ToolType": "MODEL_CONTEXT_PROTOCOL",
              "ToolId": "copied-tool"
            }]
          }
        JSON
        prompt_text     = <<-YAML
          system: |
            Voice orchestration protocol.
            {{$.toolConfigurationList}}
          messages:
            - '{{$.conversationHistory}}'
            - role: assistant
              content: '<message>'
        YAML
      }
    }
  }
}

variables {
  assistant_id         = "00000000-0000-0000-0000-000000000001"
  connect_instance_arn = "arn:aws:connect:us-east-1:123456789012:instance/00000000-0000-0000-0000-000000000005"
  knowledge_base_id    = "4dbc482c-d939-440d-aca7-081921f95571"
  agent_name           = "BTSGSD-V2V-US-SupportAgent"
  prompt_name          = "BTSGSD-V2V-US-SupportAgent-prompt"
  prompt_yaml_file     = "tests/fixtures/complete_system.yaml"
  tool_configurations = [
    for name in [
      "BTSGSD-V2V-US-nexthink-handoff___handoff",
      "BTSGSD-V2V-US-snow-interaction___Interaction__Interaction",
      "BTSGSD-V2V-US-snow-userlookup___UserLookUp___UserLookUp",
      ] : {
      ToolName = name
      ToolType = "MODEL_CONTEXT_PROTOCOL"
      ToolId   = "gateway_gateway-0123456789__${name}"
    }
  ]
}

run "agent_and_prompt_are_awscc_resources_on_the_target_assistant" {
  command = plan

  assert {
    condition = (
      awscc_wisdom_ai_agent.support.name == "BTSGSD-V2V-US-SupportAgent" &&
      awscc_wisdom_ai_agent.support.type == "ORCHESTRATION" &&
      awscc_wisdom_ai_agent.support.assistant_id == var.assistant_id &&
      awscc_wisdom_ai_agent.support.configuration.orchestration_ai_agent_configuration.connect_instance_arn == var.connect_instance_arn &&
      awscc_wisdom_ai_agent.support.configuration.orchestration_ai_agent_configuration.locale == "en_US" &&
      awscc_wisdom_ai_prompt.support.name == "BTSGSD-V2V-US-SupportAgent-prompt" &&
      awscc_wisdom_ai_prompt.support.type == "ORCHESTRATION" &&
      awscc_wisdom_ai_prompt.support.api_format == "MESSAGES" &&
      awscc_wisdom_ai_prompt.support.model_id == "global.anthropic.claude-sonnet-5"
    )
    error_message = "Deploy the orchestration agent and its global Sonnet 5 prompt through awscc on the target assistant and instance."
  }

  assert {
    condition     = length(terraform_data.admin_mcp_access) == 0
    error_message = "Existing callers must not modify Admin MCP access unless explicitly enabled."
  }
}

run "knowledge_base_is_associated_with_the_target_assistant" {
  command = plan

  assert {
    condition = (
      awscc_wisdom_assistant_association.knowledge_base.assistant_id == var.assistant_id &&
      awscc_wisdom_assistant_association.knowledge_base.association_type == "KNOWLEDGE_BASE" &&
      awscc_wisdom_assistant_association.knowledge_base.association.knowledge_base_id == "4dbc482c-d939-440d-aca7-081921f95571"
    )
    error_message = "The target assistant must be associated with the knowledge base the dev Retrieve tool searches."
  }
}

run "tools_mirror_dev_in_order_with_the_gateway_tools_first" {
  command = apply

  assert {
    condition = [
      for tool in awscc_wisdom_ai_agent.support.configuration.orchestration_ai_agent_configuration.tool_configurations : tool.tool_name
      ] == [
      "BTSGSD-V2V-US-nexthink-handoff___handoff",
      "BTSGSD-V2V-US-snow-interaction___Interaction__Interaction",
      "BTSGSD-V2V-US-snow-userlookup___UserLookUp___UserLookUp",
      "Retrieve",
      "Complete",
      "Escalate",
    ]
    error_message = "Tools must be the gateway tools followed by Retrieve, Complete and Escalate, as on the dev agent."
  }

  assert {
    condition = alltrue([
      for index, name in ["Retrieve", "Complete", "Escalate"] :
      jsondecode(awscc_wisdom_ai_agent.support.configuration.orchestration_ai_agent_configuration.tool_configurations[index + 3].input_schema) ==
      jsondecode(file("${path.module}/assets/tools/${lower(name)}.json")).inputSchema
    ])
    error_message = "Each mirrored tool must carry the dev input schema unchanged."
  }

  assert {
    condition = (
      awscc_wisdom_ai_agent.support.configuration.orchestration_ai_agent_configuration.tool_configurations[4].tool_id == "Complete" &&
      awscc_wisdom_ai_agent.support.configuration.orchestration_ai_agent_configuration.tool_configurations[5].tool_id == "Escalate" &&
      awscc_wisdom_ai_agent.support.configuration.orchestration_ai_agent_configuration.tool_configurations[3].tool_id == "aws_service__qconnect_Retrieve" &&
      awscc_wisdom_ai_agent.support.configuration.orchestration_ai_agent_configuration.tool_configurations[3].tool_type == "MODEL_CONTEXT_PROTOCOL" &&
      awscc_wisdom_ai_agent.support.configuration.orchestration_ai_agent_configuration.tool_configurations[4].tool_type == "RETURN_TO_CONTROL" &&
      # Empty dev examples/annotations are omitted: the API drops them, and
      # sending them leaves a permanent in-place diff on the agent.
      # Checked on what the module sends; the mock fills omitted values on apply.
      alltrue([for index in [3, 4, 5] : local.tool_configurations[index].instruction.examples == null]) &&
      local.tool_configurations[3].annotations == null &&
      awscc_wisdom_ai_agent.support.configuration.orchestration_ai_agent_configuration.tool_configurations[4].instruction.instruction == jsondecode(file("${path.module}/assets/tools/complete.json")).instruction.instruction &&
      awscc_wisdom_ai_agent.support.configuration.orchestration_ai_agent_configuration.tool_configurations[5].user_interaction_configuration.is_user_confirmation_required == false
    )
    error_message = "Tool IDs, types, instructions, examples and confirmation settings must match the dev tools."
  }
}

run "schemas_keep_numbers_and_booleans" {
  command = apply

  assert {
    condition = (
      jsondecode(awscc_wisdom_ai_agent.support.configuration.orchestration_ai_agent_configuration.tool_configurations[4].input_schema).additionalProperties == false &&
      jsondecode(awscc_wisdom_ai_agent.support.configuration.orchestration_ai_agent_configuration.tool_configurations[4].input_schema).properties.reason.minLength == 8 &&
      jsondecode(awscc_wisdom_ai_agent.support.configuration.orchestration_ai_agent_configuration.tool_configurations[5].input_schema).properties.CallSummary.minLength == 20 &&
      !strcontains(awscc_wisdom_ai_agent.support.configuration.orchestration_ai_agent_configuration.tool_configurations[4].input_schema, "\"additionalProperties\":\"false\"")
    )
    error_message = "Schemas must keep JSON booleans and numbers; the CloudFormation deployment stored them as strings."
  }
}

run "retrieve_searches_the_target_assistant_association" {
  command = apply

  assert {
    condition = {
      for override in awscc_wisdom_ai_agent.support.configuration.orchestration_ai_agent_configuration.tool_configurations[3].override_input_values :
      override.json_path => override.value.constant
      } == {
      "$.assistantId" = {
        type  = "STRING"
        value = "00000000-0000-0000-0000-000000000001"
      }
      "$.retrievalConfiguration.knowledgeSource.assistantAssociationIds" = {
        type  = "JSON_STRING"
        value = "[\"00000000-0000-0000-0000-0000000000aa\"]"
      }
    }
    error_message = "Retrieve must pin this assistant and its knowledge-base association, as the dev tool pins its own."
  }

  assert {
    condition = (
      length(awscc_wisdom_ai_agent.support.configuration.orchestration_ai_agent_configuration.tool_configurations[3].override_input_values) == 2 &&
      !strcontains(jsonencode(awscc_wisdom_ai_agent.support.configuration), "bc274e3f") &&
      !strcontains(jsonencode(awscc_wisdom_ai_agent.support.configuration), "ede5afd1") &&
      !strcontains(jsonencode(awscc_wisdom_ai_agent.support.configuration), "c227a737")
    )
    error_message = "No dev instance, assistant or association ID may remain in the agent configuration."
  }
}

run "versions_are_published_and_exposed" {
  command = apply

  assert {
    condition = (
      awscc_wisdom_ai_agent.support.configuration.orchestration_ai_agent_configuration.orchestration_ai_prompt_id == "00000000-0000-0000-0000-0000000000b1:3" &&
      awscc_wisdom_ai_agent_version.support.ai_agent_id == awscc_wisdom_ai_agent.support.ai_agent_id &&
      awscc_wisdom_ai_agent_version.support.modified_time_seconds == awscc_wisdom_ai_agent.support.modified_time_seconds &&
      awscc_wisdom_ai_prompt_version.support.modified_time_seconds == awscc_wisdom_ai_prompt.support.modified_time_seconds &&
      output.agent_version_arn == "arn:aws:wisdom:us-east-1:123456789012:ai-agent/00000000-0000-0000-0000-000000000001/00000000-0000-0000-0000-0000000000c1:7" &&
      output.deployment.AgentVersion == "7" &&
      output.deployment.PromptVersion == "3" &&
      output.deployment.KnowledgeBaseAssociationId == "00000000-0000-0000-0000-0000000000aa" &&
      output.assistant_arn == "arn:aws:wisdom:us-east-1:123456789012:assistant/00000000-0000-0000-0000-000000000001"
    )
    error_message = "The agent must use the published prompt version and expose a version-qualified ARN for routing."
  }
}

run "agent_arn_without_latest_qualifier" {
  command = apply

  override_resource {
    target = awscc_wisdom_ai_agent.support
    values = {
      ai_agent_id           = "00000000-0000-0000-0000-0000000000c1"
      ai_agent_arn          = "arn:aws:wisdom:us-east-1:123456789012:ai-agent/00000000-0000-0000-0000-000000000001/00000000-0000-0000-0000-0000000000c1:$LATEST"
      assistant_arn         = "arn:aws:wisdom:us-east-1:123456789012:assistant/00000000-0000-0000-0000-000000000001"
      modified_time_seconds = 1700000001
    }
  }

  assert {
    condition     = output.agent_version_arn == "arn:aws:wisdom:us-east-1:123456789012:ai-agent/00000000-0000-0000-0000-000000000001/00000000-0000-0000-0000-0000000000c1:7"
    error_message = "A :$LATEST qualifier on the agent ARN must not leak into the version ARN."
  }
}

run "reject_gateway_tool_named_like_a_mirrored_tool" {
  command = plan

  variables {
    tool_configurations = [{
      ToolName = "Retrieve"
      ToolType = "MODEL_CONTEXT_PROTOCOL"
      ToolId   = "gateway_x__Retrieve"
    }]
  }

  expect_failures = [awscc_wisdom_ai_agent.support]
}

run "reject_invalid_knowledge_base_id" {
  command = plan

  variables {
    knowledge_base_id = "btsgsd-knowledgebase"
  }

  expect_failures = [var.knowledge_base_id]
}

run "voice_prompt_uses_the_complete_custom_system" {
  command = plan

  assert {
    condition = (
      !strcontains(yamldecode(local.prompt_text).system, "Voice orchestration protocol.") &&
      strcontains(yamldecode(local.prompt_text).system, "{{$.toolConfigurationList}}") &&
      strcontains(yamldecode(local.prompt_text).system, trimspace(local.custom_prompt.system)) &&
      length(yamldecode(local.prompt_text).system) <= 100000 &&
      length(yamldecode(local.prompt_text).messages) == 1 &&
      yamldecode(local.prompt_text).messages[0] == "{{$.conversationHistory}}" &&
      !contains(keys(yamldecode(local.prompt_text)), "test_question") &&
      awscc_wisdom_ai_prompt.support.template_configuration.text_full_ai_prompt_edit_template_configuration.text == local.prompt_text
    )
    error_message = "Use the complete custom system without duplicating the source, preserve runtime tools/messages, and stay within the system length limit."
  }
}

run "support_agent_prompt_file" {
  command = plan

  variables {
    source_prompt_name = "SelfServiceOrchestrationVoice"
    prompt_yaml_file   = "../../environments/v2v-dev/metadata/prompts/btsgsd-SupportAgent-prompt.yaml"
  }

  assert {
    condition = (
      strcontains(yamldecode(local.prompt_text).system, trimspace(local.custom_prompt.system)) &&
      !strcontains(yamldecode(local.prompt_text).system, "Voice orchestration protocol.") &&
      strcontains(yamldecode(local.prompt_text).system, "{{$.toolConfigurationList}}") &&
      length(yamldecode(local.prompt_text).system) <= 100000 &&
      yamldecode(local.prompt_text).messages == local.custom_prompt.messages &&
      !contains(keys(yamldecode(local.prompt_text)), "name") &&
      !contains(keys(yamldecode(local.prompt_text)), "description") &&
      data.external.source.query.source_name == "SelfServiceOrchestratorVoice" &&
      data.external.source.query.source_prompt_name == "SelfServiceOrchestrationVoice"
    )
    error_message = "Preserve the complete supplied instructions and conversation messages while keeping metadata outside the runtime prompt."
  }
}

run "missing_prompt_file" {
  command = plan
  variables {
    prompt_yaml_file = "tests/fixtures/missing.yaml"
  }
  expect_failures = [var.prompt_yaml_file]
}

run "blank_prompt" {
  command = plan
  variables {
    prompt_yaml_file = "tests/fixtures/blank_prompt.yaml"
  }
  expect_failures = [var.prompt_yaml_file]
}

run "blank_system" {
  command = plan
  variables {
    prompt_yaml_file = "tests/fixtures/blank_system.yaml"
  }
  expect_failures = [var.prompt_yaml_file]
}

run "missing_instruction_key" {
  command = plan
  variables {
    prompt_yaml_file = "tests/fixtures/missing_instruction_key.yaml"
  }
  expect_failures = [var.prompt_yaml_file]
}

run "complete_system_replaces_source" {
  command = plan
  override_data {
    target = data.external.source
    values = {
      result = {
        source_agent_id = "00000000-0000-0000-0000-000000000002"
        configuration   = "{}"
        prompt_text     = <<-YAML
          system: Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol. Source protocol.
          messages:
            - 'Source message should be replaced.'
        YAML
      }
    }
  }
  assert {
    condition = (
      length(local.source_prompt.system) > length(local.custom_instructions) &&
      !strcontains(yamldecode(local.prompt_text).system, "Source protocol.") &&
      strcontains(yamldecode(local.prompt_text).system, trimspace(local.custom_prompt.system)) &&
      yamldecode(local.prompt_text).messages[0] == "{{$.conversationHistory}}"
    )
    error_message = "A complete system prompt must replace the source system and messages."
  }
}

run "oversized_system" {
  command = plan
  variables {
    prompt_yaml_file = "tests/fixtures/oversized_system.yaml"
  }
  expect_failures = [awscc_wisdom_ai_prompt.support]
}

run "support_agent_admin_mcp_tools" {
  command = plan
  variables {
    admin_mcp_access = {
      namespace = "gateway-0123456789"
    }
  }

  # Plan only: the grant runs a local script. The awscc agent ARNs are known
  # after apply, so check their count here (Terraform 1.10 has no override_during).
  assert {
    condition = (
      length(terraform_data.admin_mcp_access) == 1 &&
      terraform_data.admin_mcp_access[0].input.namespace == "gateway-0123456789" &&
      terraform_data.admin_mcp_access[0].input.connect_instance_arn == var.connect_instance_arn &&
      toset(terraform_data.admin_mcp_access[0].input.tool_names) == toset([
        "BTSGSD-V2V-US-nexthink-handoff___handoff",
        "BTSGSD-V2V-US-snow-interaction___Interaction__Interaction",
        "BTSGSD-V2V-US-snow-userlookup___UserLookUp___UserLookUp",
      ]) &&
      length(terraform_data.admin_mcp_access[0].input.agent_arns) == 2
    )
    error_message = "The grant must use the gateway namespace, exact tool names, and the agent and version ARNs."
  }
}

run "admin_tools_must_belong_to_selected_gateway" {
  command = plan
  variables {
    admin_mcp_access = { namespace = "other-gateway" }
    tool_configurations = [{
      ToolName = "handoff"
      ToolType = "MODEL_CONTEXT_PROTOCOL"
      ToolId   = "gateway_gateway-0123456789__handoff"
    }]
  }
  expect_failures = [var.admin_mcp_access]
}
