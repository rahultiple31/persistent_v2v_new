terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.100"
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
    region               = data.aws_region.current.name
    aws_profile          = var.aws_profile
    source_name          = var.source_agent_name
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

  # Preserve the system voice protocol and runtime placeholders; exclude test metadata.
  prompt_text = yamlencode(merge(local.source_prompt, {
    system = <<-SYSTEM
      ${local.source_prompt.system}

      <customer_service_policy>
      ${trimspace(local.custom_prompt.prompt)}
      </customer_service_policy>
    SYSTEM

    # Claude Sonnet 5 rejects a final assistant message prefill.
    messages = [
      for index, message in local.source_prompt.messages : message
      if !(index == length(local.source_prompt.messages) - 1 && try(message.role == "assistant", false))
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
              ConnectInstanceArn = var.connect_instance_arn
              OrchestrationAIPromptId = {
                "Fn::Join" = [":", [
                  { "Fn::GetAtt" = ["SupportPrompt", "AIPromptId"] },
                  { "Fn::GetAtt" = ["SupportPromptVersion", "VersionNumber"] }
                ]]
              }
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
      AgentVersion       = { Value = { "Fn::GetAtt" = ["SupportAgentVersion", "VersionNumber"] } }
      AgentVersionId = {
        Value = {
          "Fn::Join" = [":", [
            { "Fn::GetAtt" = ["SupportAgent", "AIAgentId"] },
            { "Fn::GetAtt" = ["SupportAgentVersion", "VersionNumber"] }
          ]]
        }
      }
      AgentVersionArn = {
        Value = {
          "Fn::Join" = [":", [
            { "Fn::GetAtt" = ["SupportAgent", "AIAgentArn"] },
            { "Fn::GetAtt" = ["SupportAgentVersion", "VersionNumber"] }
          ]]
        }
      }
      PromptId      = { Value = { "Fn::GetAtt" = ["SupportPrompt", "AIPromptId"] } }
      PromptVersion = { Value = { "Fn::GetAtt" = ["SupportPromptVersion", "VersionNumber"] } }
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
  }
}

resource "aws_cloudformation_stack" "agent" {
  name = var.stack_name
  tags = local.tags
  template_url = format(
    "https://s3.%s.%s/%s/%s",
    data.aws_region.current.name,
    data.aws_partition.current.dns_suffix,
    aws_s3_object.template.bucket,
    aws_s3_object.template.key
  )
}
