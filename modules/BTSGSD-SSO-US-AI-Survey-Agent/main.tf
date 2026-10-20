terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.100.0, < 7.0.0"
    }
  }
}

data "aws_region" "current" {}

data "aws_connect_security_profile" "admin" {
  instance_id = local.instance_id
  name        = "Admin"
}

locals {
  instance_id = split("/", var.connect_instance_arn)[1]
  agent_name  = "BTSGSD-SSO-US-AI-Survey-Agent"

  tools = [
    {
      ToolName = "UpdateLanguage"
      ToolType = "RETURN_TO_CONTROL"

      Instruction = {
        Instruction = <<-TEXT
          Use this tool before the call is being handed off to a human representative.
          Save all the caller information collected during the conversation such as Language Detected.
          Do not invent information.
          If a value was not collected, leave it blank.
          After using this tool, return control to the contact flow.
        TEXT
      }

      InputSchema = {
        type = "object"
        properties = {
          LanguageDetected = {
            type        = "string"
            description = "The caller's Detected language "
          }
        }
        required = ["LanguageDetected"]
      }
    },
    {
      ToolName = "UpdateSurveyResults"
      ToolType = "RETURN_TO_CONTROL"

      Instruction = {
        Instruction = <<-TEXT
          Use this tool when the survey reaches a final outcome.

          Save the survey results collected during the conversation.

          Populate:
          - SurveyIntent
          - SurveyQ1
          - SurveyQ2
          - SurveyQ3

          Do not invent values.
          Only save responses explicitly provided by the customer.

          SurveyIntent must be either:
          - surveyCompleted
          - wantToleaveRecommendation

          SurveyQ1, SurveyQ2 and SurveyQ3 must be:
          - yes
          - no

          After using this tool, return control to the contact flow.
        TEXT
      }

      InputSchema = {
        type = "object"
        properties = {
          SurveyIntent = {
            type        = "string"
            description = "Survey outcome"
          }
          SurveyQ2 = {
            type        = "string"
            description = "Question 2 response"
          }
          SurveyQ1 = {
            type        = "string"
            description = "Question 1 response"
          }
          SurveyQ3 = {
            type        = "string"
            description = "Question 3 response"
          }
        }
        required = [
          "SurveyIntent",
          "SurveyQ1",
          "SurveyQ2",
          "SurveyQ3"
        ]
      }
    }
  ]

  template = jsonencode({
    AWSTemplateFormatVersion = "2010-09-09"

    Resources = {
      SurveyAgent = {
        Type = "AWS::Wisdom::AIAgent"
        Properties = {
          AssistantId = var.assistant_id
          Name        = local.agent_name
          Description = "English US survey orchestration agent."
          Type        = "ORCHESTRATION"

          Configuration = {
            OrchestrationAIAgentConfiguration = {
              ConnectInstanceArn      = var.connect_instance_arn
              Locale                  = "en_US"
              OrchestrationAIPromptId = var.orchestration_prompt_id
              ToolConfigurations      = local.tools
            }
          }
        }
      }

      SurveyAgentVersion = {
        Type = "AWS::Wisdom::AIAgentVersion"
        Properties = {
          AssistantId         = var.assistant_id
          AIAgentId           = { "Fn::GetAtt" = ["SurveyAgent", "AIAgentId"] }
          ModifiedTimeSeconds = { "Fn::GetAtt" = ["SurveyAgent", "ModifiedTimeSeconds"] }
        }
      }
    }

    Outputs = {
      AgentId = {
        Value = { "Fn::GetAtt" = ["SurveyAgent", "AIAgentId"] }
      }
      AgentArn = {
        Value = { "Fn::GetAtt" = ["SurveyAgent", "AIAgentArn"] }
      }
      AgentVersionId = {
        Value = { "Fn::GetAtt" = ["SurveyAgentVersion", "AIAgentVersionId"] }
      }
    }
  })

  agent_version = split(
    ":",
    aws_cloudformation_stack.survey.outputs["AgentVersionId"]
  )[1]

  agent_version_arn = "${aws_cloudformation_stack.survey.outputs["AgentArn"]}:${local.agent_version}"
}

resource "aws_cloudformation_stack" "survey" {
  name          = local.agent_name
  template_body = local.template
}

# Assign the existing Admin profile through AWS CLI on the Ubuntu pipeline runner.
resource "terraform_data" "admin_assignment" {
  triggers_replace = {
    template_hash = sha256(local.template)
    agent_arn     = aws_cloudformation_stack.survey.outputs["AgentArn"]
    version_arn   = local.agent_version_arn
    profile_id    = data.aws_connect_security_profile.admin.security_profile_id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]

    command = <<-BASH
      set -euo pipefail

      for entity_arn in "$AGENT_LATEST_ARN" "$AGENT_VERSION_ARN"; do
        profiles="$(aws connect list-entity-security-profiles \
          --instance-id "$INSTANCE_ID" \
          --entity-type AI_AGENT \
          --entity-arn "$entity_arn" \
          --region "$AWS_REGION" \
          --query 'SecurityProfiles[].Id' \
          --output text \
          --no-cli-pager)"

        if printf '%s\n' "$profiles" | tr '\t' '\n' | grep -Fxq "$ADMIN_PROFILE_ID"; then
          continue
        fi

        aws connect associate-security-profiles \
          --instance-id "$INSTANCE_ID" \
          --entity-type AI_AGENT \
          --entity-arn "$entity_arn" \
          --security-profiles "$SECURITY_PROFILES" \
          --region "$AWS_REGION" \
          --no-cli-pager
      done
    BASH

    environment = {
      AWS_REGION        = data.aws_region.current.region
      INSTANCE_ID       = local.instance_id
      AGENT_LATEST_ARN  = "${aws_cloudformation_stack.survey.outputs["AgentArn"]}:$LATEST"
      AGENT_VERSION_ARN = local.agent_version_arn
      ADMIN_PROFILE_ID  = data.aws_connect_security_profile.admin.security_profile_id
      SECURITY_PROFILES = jsonencode([
        { Id = data.aws_connect_security_profile.admin.security_profile_id }
      ])
      AWS_PAGER           = ""
      AWS_CLI_AUTO_PROMPT = "off"
    }
  }
}
