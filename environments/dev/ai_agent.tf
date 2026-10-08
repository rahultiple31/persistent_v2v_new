locals {
  dev_ai_domain_enabled  = var.dev_ai_domain_enabled && local.deploy_connect
  dev_ai_enabled         = var.dev_ai_agent_enabled && local.deploy_connect
  dev_support_ai_enabled = var.dev_support_ai_agent_enabled && local.deploy_connect
  dev_survey_ai_enabled  = var.dev_survey_ai_agent_enabled && local.deploy_connect
  # Retain the private bucket while its name is configured, even without an agent.
  dev_ai_template_bucket_enabled = var.dev_ai_template_bucket != null && local.deploy_connect
  dev_ai_assistant_id            = local.dev_ai_domain_enabled ? aws_cloudformation_stack.dev_ai_domain[0].outputs["AssistantId"] : var.dev_ai_assistant_id
  dev_ai_name_prefix             = lower(replace(coalesce(var.connect_instance_alias, local.name_prefix), "_", "-"))
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
          AssistantId  = local.dev_ai_assistant_id
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
          AssistantId         = local.dev_ai_assistant_id
          AIPromptId          = { "Fn::GetAtt" = ["DevPrompt", "AIPromptId"] }
          ModifiedTimeSeconds = { "Fn::GetAtt" = ["DevPrompt", "ModifiedTimeSeconds"] }
        }
      }

      DevAIAgent = {
        Type = "AWS::Wisdom::AIAgent"
        Properties = {
          AssistantId = local.dev_ai_assistant_id
          Name        = "${local.dev_ai_name_prefix}-customer-service-ai"
          Description = var.dev_ai_agent_test_mode ? "Prompt-only Dev smoke-test agent without retrieval or action tools." : "Dev customer-service orchestration agent."
          Type        = "ORCHESTRATION"
          Tags        = local.dev_ai_tags
          Configuration = {
            OrchestrationAIAgentConfiguration = merge({
              ConnectInstanceArn = module.connect_us_east_1[0].instance_arn
              Locale             = "en_US"
              OrchestrationAIPromptId = {
                "Fn::Join" = [":", [
                  { "Fn::GetAtt" = ["DevPrompt", "AIPromptId"] },
                  { "Fn::GetAtt" = ["DevPromptVersion", "VersionNumber"] }
                ]]
              }
            }, try(length(var.dev_ai_tools) > 0, false) ? { ToolConfigurations = var.dev_ai_tools } : {})
          }
        }
      }

      DevAIAgentVersion = {
        Type = "AWS::Wisdom::AIAgentVersion"
        Properties = {
          AssistantId         = local.dev_ai_assistant_id
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
        Value = local.dev_ai_assistant_id
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

resource "aws_cloudformation_stack" "dev_ai_domain" {
  count    = local.dev_ai_domain_enabled ? 1 : 0
  provider = aws.us_east_1
  name     = "${local.dev_ai_name_prefix}-ai-domain"
  tags     = local.dev_ai_tags

  template_body = jsonencode({
    AWSTemplateFormatVersion = "2010-09-09"
    Resources = {
      DevAssistant = {
        Type = "AWS::Wisdom::Assistant"
        Properties = {
          Name        = "${local.dev_ai_name_prefix}-ai-domain"
          Description = "AI agent domain for the Dev Amazon Connect instance."
          Type        = "AGENT"
          Tags        = [for key, value in local.dev_ai_tags : { Key = key, Value = value }]
        }
      }
      DevConnectAssociation = {
        Type = "AWS::Connect::IntegrationAssociation"
        Properties = {
          # CloudFormation requires the instance ARN, not the UUID, here.
          InstanceId      = module.connect_us_east_1[0].instance_arn
          IntegrationType = "WISDOM_ASSISTANT"
          IntegrationArn  = { "Fn::GetAtt" = ["DevAssistant", "AssistantArn"] }
        }
      }
    }
    Outputs = {
      DomainName = {
        Value = "${local.dev_ai_name_prefix}-ai-domain"
      }
      AssistantId = {
        Value = { Ref = "DevAssistant" }
      }
      AssistantArn = {
        Value = { "Fn::GetAtt" = ["DevAssistant", "AssistantArn"] }
      }
      ConnectInstanceArn = {
        Value = module.connect_us_east_1[0].instance_arn
      }
    }
  })
}

resource "aws_s3_bucket" "dev_ai_template" {
  count         = local.dev_ai_template_bucket_enabled ? 1 : 0
  provider      = aws.us_east_1
  bucket        = var.dev_ai_template_bucket
  force_destroy = false
  tags          = local.dev_ai_tags
}

resource "aws_s3_bucket_public_access_block" "dev_ai_template" {
  count    = local.dev_ai_template_bucket_enabled ? 1 : 0
  provider = aws.us_east_1
  bucket   = aws_s3_bucket.dev_ai_template[count.index].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "dev_ai_template" {
  count    = local.dev_ai_template_bucket_enabled ? 1 : 0
  provider = aws.us_east_1
  bucket   = aws_s3_bucket.dev_ai_template[count.index].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# The full prompt exceeds CloudFormation's inline template size limit.
resource "aws_s3_object" "dev_ai_template" {
  count        = local.dev_ai_enabled ? 1 : 0
  provider     = aws.us_east_1
  bucket       = aws_s3_bucket.dev_ai_template[count.index].id
  key          = "ai-agents/${sha256(local.dev_ai_template)}.json"
  content      = local.dev_ai_template
  content_type = "application/json"
  tags         = local.dev_ai_tags

  depends_on = [
    aws_s3_bucket_public_access_block.dev_ai_template,
    aws_s3_bucket_server_side_encryption_configuration.dev_ai_template
  ]

  lifecycle {
    create_before_destroy = true
  }
}

resource "terraform_data" "dev_ai_model_validation" {
  count = local.dev_ai_enabled ? 1 : 0

  triggers_replace = {
    assistant_id = local.dev_ai_assistant_id
    model_id     = var.dev_ai_prompt_model_id
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      DEV_AI_ASSISTANT_ID = local.dev_ai_assistant_id
      DEV_AI_MODEL_ID     = var.dev_ai_prompt_model_id
      AWS_REGION          = "us-east-1"
      AWS_DEFAULT_REGION  = "us-east-1"
      AWS_PAGER           = ""
    }
    command = <<-BASH
      set -euo pipefail
      set -f

      if ! command -v aws >/dev/null 2>&1; then
        echo "Dev AI model validation requires AWS CLI v2 on the Terraform runner." >&2
        exit 1
      fi

      available_models=$(aws qconnect list-models \
        --assistant-id "$DEV_AI_ASSISTANT_ID" \
        --ai-prompt-type ORCHESTRATION \
        --region us-east-1 \
        --query 'modelSummaries[].modelId' \
        --output text \
        --no-cli-pager)

      for model in $available_models; do
        if [ "$model" = "$DEV_AI_MODEL_ID" ]; then
          echo "Verified Dev orchestration model: $DEV_AI_MODEL_ID"
          exit 0
        fi
      done

      echo "Model '$DEV_AI_MODEL_ID' is not available for the Dev assistant in us-east-1." >&2
      echo "Available orchestration model IDs:" >&2
      printf '%s\n' "$available_models" >&2
      echo "Set dev_ai_prompt_model_id to an exact available ID and generate a fresh plan." >&2
      exit 1
    BASH
  }
}

resource "aws_cloudformation_stack" "dev_ai_agent" {
  count    = local.dev_ai_enabled ? 1 : 0
  provider = aws.us_east_1
  name     = "${local.dev_ai_name_prefix}-ai-agent"
  tags     = local.dev_ai_tags

  template_url = "https://s3.us-east-1.amazonaws.com/${aws_s3_bucket.dev_ai_template[count.index].id}/${aws_s3_object.dev_ai_template[count.index].key}"

  depends_on = [terraform_data.dev_ai_model_validation]
}
