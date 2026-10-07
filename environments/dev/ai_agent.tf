locals {
  dev_ai_enabled     = var.dev_ai_agent_enabled && local.deploy_connect
  dev_ai_name_prefix = lower(replace(coalesce(var.connect_instance_alias, local.name_prefix), "_", "-"))
  dev_ai_tags = merge(local.common_tags, {
    Platform             = "Amazon Connect AI Agent"
    AmazonConnectEnabled = "True"
  })

  # Read the prompt unchanged and let Connect resolve its runtime placeholders.
  dev_ai_template = local.dev_ai_enabled ? jsonencode({
    AWSTemplateFormatVersion = "2010-09-09"
    Resources = {
      DevPrompt = {
        Type = "AWS::Wisdom::AIPrompt"
        Properties = {
          AssistantId  = var.dev_ai_assistant_id
          Name         = "${local.dev_ai_name_prefix}-AgentAssistanceOrchestration"
          Type         = "ORCHESTRATION"
          ApiFormat    = "MESSAGES"
          TemplateType = "TEXT"
          ModelId      = var.dev_ai_prompt_model_id
          Tags         = local.dev_ai_tags
          TemplateConfiguration = {
            TextFullAIPromptEditTemplateConfiguration = {
              Text = file("${path.module}/${var.dev_ai_prompt_file}")
            }
          }
        }
      }

      DevPromptVersion = {
        Type = "AWS::Wisdom::AIPromptVersion"
        Properties = {
          AssistantId         = var.dev_ai_assistant_id
          AIPromptId          = { "Fn::GetAtt" = ["DevPrompt", "AIPromptId"] }
          ModifiedTimeSeconds = { "Fn::GetAtt" = ["DevPrompt", "ModifiedTimeSeconds"] }
        }
      }

      DevAIAgent = {
        Type = "AWS::Wisdom::AIAgent"
        Properties = {
          AssistantId = var.dev_ai_assistant_id
          Name        = "${local.dev_ai_name_prefix}-customer-service-ai"
          Type        = "ORCHESTRATION"
          Tags        = local.dev_ai_tags
          Configuration = {
            OrchestrationAIAgentConfiguration = {
              ConnectInstanceArn = module.connect_us_east_1[0].instance_arn
              Locale             = "en_US"
              ToolConfigurations = var.dev_ai_tools
              OrchestrationAIPromptId = {
                "Fn::Join" = [":", [
                  { "Fn::GetAtt" = ["DevPrompt", "AIPromptId"] },
                  { "Fn::GetAtt" = ["DevPromptVersion", "VersionNumber"] }
                ]]
              }
            }
          }
        }
      }

      DevAIAgentVersion = {
        Type = "AWS::Wisdom::AIAgentVersion"
        Properties = {
          AssistantId         = var.dev_ai_assistant_id
          AIAgentId           = { "Fn::GetAtt" = ["DevAIAgent", "AIAgentId"] }
          ModifiedTimeSeconds = { "Fn::GetAtt" = ["DevAIAgent", "ModifiedTimeSeconds"] }
        }
      }
    }

    Outputs = {
      ConnectInstanceArn = {
        Value = module.connect_us_east_1[0].instance_arn
      }
      AssistantId = {
        Value = var.dev_ai_assistant_id
      }
      AgentId = {
        Value = { "Fn::GetAtt" = ["DevAIAgent", "AIAgentId"] }
      }
      AgentVersion = {
        Value = { "Fn::GetAtt" = ["DevAIAgentVersion", "VersionNumber"] }
      }
      PromptId = {
        Value = { "Fn::GetAtt" = ["DevPrompt", "AIPromptId"] }
      }
      PromptVersion = {
        Value = { "Fn::GetAtt" = ["DevPromptVersion", "VersionNumber"] }
      }
    }
  }) : null
}

# The full prompt exceeds CloudFormation's inline template size limit.
resource "aws_s3_object" "dev_ai_template" {
  count        = local.dev_ai_enabled ? 1 : 0
  provider     = aws.us_east_1
  bucket       = var.dev_ai_template_bucket
  key          = "ai-agents/${sha256(local.dev_ai_template)}.json"
  content      = local.dev_ai_template
  content_type = "application/json"
  tags         = local.dev_ai_tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_cloudformation_stack" "dev_ai_agent" {
  count    = local.dev_ai_enabled ? 1 : 0
  provider = aws.us_east_1
  name     = "${local.dev_ai_name_prefix}-ai-agent"
  tags     = local.dev_ai_tags

  template_url = "https://s3.us-east-1.amazonaws.com/${var.dev_ai_template_bucket}/${aws_s3_object.dev_ai_template[count.index].key}"
}
