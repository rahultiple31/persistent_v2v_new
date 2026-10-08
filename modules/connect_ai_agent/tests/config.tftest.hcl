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

mock_provider "external" {
  mock_data "external" {
    defaults = {
      result = {
        source_agent_id = "00000000-0000-0000-0000-000000000002"
        configuration   = <<-JSON
          {
            "Locale": "en_US",
            "OrchestrationAIGuardrailId": "00000000-0000-0000-0000-000000000003:1",
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
  template_bucket_name = "test-ai-agent-template-bucket"
  prompt_yaml_file     = "../../environments/dev/metadata/prompts/btsgsd-support_prompts.yaml"
}

run "voice_agent_template" {
  command = plan

  assert {
    condition = (
      jsondecode(aws_s3_object.template.content).Resources.SupportAgent.Properties.Name == "btsgsd-support-agent" &&
      jsondecode(aws_s3_object.template.content).Resources.SupportAgent.Properties.Type == "ORCHESTRATION" &&
      jsondecode(aws_s3_object.template.content).Resources.SupportPrompt.Properties.Name == "btsgsd-support_prompts" &&
      jsondecode(aws_s3_object.template.content).Resources.SupportPrompt.Properties.ModelId == "global.anthropic.claude-sonnet-5"
    )
    error_message = "The template must deploy the requested orchestration agent and global Sonnet 5 prompt."
  }

  assert {
    condition = (
      local.source_configuration.ToolConfigurations[0].ToolId == "copied-tool" &&
      jsondecode(aws_s3_object.template.content).Resources.SupportAgent.Properties.Configuration.OrchestrationAIAgentConfiguration.OrchestrationAIGuardrailId == "00000000-0000-0000-0000-000000000003:1"
    )
    error_message = "The custom agent must retain the source tools and guardrail."
  }

  assert {
    condition = (
      strcontains(yamldecode(local.prompt_text).system, "Voice orchestration protocol.") &&
      strcontains(yamldecode(local.prompt_text).system, "{{$.toolConfigurationList}}") &&
      strcontains(yamldecode(local.prompt_text).system, "Never provide passwords") &&
      length(yamldecode(local.prompt_text).messages) == 1 &&
      yamldecode(local.prompt_text).messages[0] == "{{$.conversationHistory}}" &&
      !contains(keys(yamldecode(local.prompt_text)), "test_question")
    )
    error_message = "Preserve voice protocol/runtime context, add custom instructions, and exclude metadata/prefill."
  }

  assert {
    condition = (
      aws_s3_object.template.server_side_encryption == "AES256" &&
      jsondecode(aws_s3_object.template.content).Outputs.AgentVersionArn.Value["Fn::Sub"][0] == "$${AgentArn}:$${AgentVersion}" &&
      jsondecode(aws_s3_object.template.content).Outputs.AgentVersionArn.Value["Fn::Sub"][1].AgentArn["Fn::GetAtt"] == ["SupportAgent", "AIAgentArn"] &&
      jsondecode(aws_s3_object.template.content).Outputs.AgentVersionArn.Value["Fn::Sub"][1].AgentVersion["Fn::Select"] == [1, { "Fn::Split" = [":", { "Fn::GetAtt" = ["SupportAgentVersion", "AIAgentVersionId"] }] }]
    )
    error_message = "Encrypt the template and expose a version-qualified agent ARN for voice routing."
  }

  assert {
    condition = (
      jsondecode(aws_s3_object.template.content).Resources.SupportAgent.Properties.Configuration.OrchestrationAIAgentConfiguration.OrchestrationAIPromptId["Fn::GetAtt"] == ["SupportPromptVersion", "AIPromptVersionId"] &&
      jsondecode(aws_s3_object.template.content).Outputs.AgentVersionId.Value["Fn::GetAtt"] == ["SupportAgentVersion", "AIAgentVersionId"]
    )
    error_message = "Use the string-valued version IDs directly for the agent's prompt and the published agent version."
  }

  assert {
    condition = (
      jsondecode(aws_s3_object.template.content).Outputs.AgentVersion.Value["Fn::Select"] == [1, { "Fn::Split" = [":", { "Fn::GetAtt" = ["SupportAgentVersion", "AIAgentVersionId"] }] }] &&
      jsondecode(aws_s3_object.template.content).Outputs.PromptVersion.Value["Fn::Select"] == [1, { "Fn::Split" = [":", { "Fn::GetAtt" = ["SupportPromptVersion", "AIPromptVersionId"] }] }]
    )
    error_message = "Version-number outputs must extract string suffixes instead of exposing numeric GetAtt attributes."
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
