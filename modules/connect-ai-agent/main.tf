locals {
  agent_name  = "BTSGSD-SSO-US-AI-Survey-Agent"
  instance_id = split("/", var.connect_instance_arn)[1]
  partition   = split(":", var.connect_instance_arn)[1]
  region      = split(":", var.connect_instance_arn)[3]
  account_id  = split(":", var.connect_instance_arn)[4]

  agent_arn = format(
    "arn:%s:wisdom:%s:%s:ai-agent/%s/%s",
    local.partition,
    local.region,
    local.account_id,
    var.assistant_id,
    awscc_wisdom_ai_agent.survey_agent.ai_agent_id
  )

  agent_version_arn = "${local.agent_arn}:${awscc_wisdom_ai_agent_version.survey.version_number}"
}

data "aws_connect_security_profile" "admin" {
  instance_id = local.instance_id
  name        = "Admin"
}

# The previous stack owns the same agent name. Finish its dedicated cleanup first.
resource "terraform_data" "retired_stack_absent" {
  triggers_replace = {
    stack_name = local.agent_name
    region     = local.region
    account_id = local.account_id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]

    command = <<-BASH
      set -euo pipefail

      actual_account="$(aws sts get-caller-identity \
        --query Account --output text --region "$AWS_REGION")"
      if [ "$actual_account" != "$EXPECTED_ACCOUNT_ID" ]; then
        echo "AWS CLI credentials do not match the Connect instance account." >&2
        exit 1
      fi

      if result="$(aws cloudformation describe-stacks \
        --stack-name "$RETIRED_STACK_NAME" \
        --region "$AWS_REGION" \
        --query 'Stacks[0].StackStatus' --output text 2>&1)"; then
        echo "The retired stack still exists: $RETIRED_STACK_NAME ($result)." >&2
        echo "Run delete-BTSGSD-SSO-US-AI-Survey-Agent with plan and apply before creating the replacement." >&2
        exit 1
      elif [[ "$result" == *"ValidationError"* && "$result" == *"does not exist"* ]]; then
        echo "Retired stack is absent; the replacement agent can be created."
      else
        printf '%s\n' "$result" >&2
        exit 1
      fi
    BASH

    environment = {
      AWS_REGION          = local.region
      EXPECTED_ACCOUNT_ID = local.account_id
      RETIRED_STACK_NAME  = local.agent_name
      AWS_PAGER           = ""
      AWS_CLI_AUTO_PROMPT = "off"
    }
  }
}

resource "awscc_wisdom_ai_agent" "survey_agent" {
  name         = local.agent_name
  type         = "ORCHESTRATION"
  assistant_id = var.assistant_id
  description  = "BTSGSD Survey AI Agent"

  configuration = {
    orchestration_ai_agent_configuration = {
      connect_instance_arn       = var.connect_instance_arn
      orchestration_ai_prompt_id = var.orchestration_prompt_id
      locale                     = "en_US"

      tool_configurations = [
        {
          tool_name = "UpdateLanguage"
          tool_type = "RETURN_TO_CONTROL"

          instruction = {
            instruction = <<-EOT
              Use this tool before the call is being handed off to a human representative.
              Save all the caller information collected during the conversation such as Language Detected.
              Do not invent information.
              If a value was not collected, leave it blank.
              After using this tool, return control to the contact flow.
            EOT
          }

          input_schema = jsonencode({
            type = "object"
            properties = {
              LanguageDetected = {
                type        = "string"
                description = "The caller's Detected language "
              }
            }
            required = ["LanguageDetected"]
          })
        },
        {
          tool_name = "UpdateSurveyResults"
          tool_type = "RETURN_TO_CONTROL"

          instruction = {
            instruction = <<-EOT
              Use this tool only once, when the survey reaches its final outcome.

              Resolve all three questions and the comments question first.
              Save the survey results collected during the conversation.

              Populate:
              - SurveyIntent
              - SurveyQ1
              - SurveyQ2
              - SurveyQ3
              - LanguageDetected

              Do not invent values.
              Only save responses explicitly provided by the customer.
              Use - only after the question's retry limit is reached.

              SurveyIntent must be either:
              - surveyCompleted
              - wantToleaveRecommendation

              SurveyQ1, SurveyQ2 and SurveyQ3 must be:
              - yes
              - no
              - "-"

              LanguageDetected must be a BCP-47 locale code.

              After using this tool, return control to the contact flow.
            EOT
          }

          input_schema = jsonencode({
            type = "object"
            properties = {
              SurveyIntent = {
                type        = "string"
                description = "Survey outcome"
                enum        = ["surveyCompleted", "wantToleaveRecommendation"]
              }
              SurveyQ2 = {
                type        = "string"
                description = "Question 2 response; - means retry limit reached."
                enum        = ["yes", "no", "-"]
              }
              SurveyQ1 = {
                type        = "string"
                description = "Question 1 response; - means retry limit reached."
                enum        = ["yes", "no", "-"]
              }
              SurveyQ3 = {
                type        = "string"
                description = "Question 3 response; - means retry limit reached."
                enum        = ["yes", "no", "-"]
              }
              LanguageDetected = {
                type        = "string"
                description = "Detected BCP-47 locale, such as en-US, es-MX or pt-BR."
              }
            }
            required = [
              "SurveyIntent",
              "SurveyQ1",
              "SurveyQ2",
              "SurveyQ3",
              "LanguageDetected"
            ]
          })
        }
      ]
    }
  }

  tags = {
    Env = "SSO"
    Org = "BTSGSD"
  }

  depends_on = [terraform_data.retired_stack_absent]
}

resource "awscc_wisdom_ai_agent_version" "survey" {
  assistant_id          = var.assistant_id
  ai_agent_id           = awscc_wisdom_ai_agent.survey_agent.ai_agent_id
  modified_time_seconds = awscc_wisdom_ai_agent.survey_agent.modified_time_seconds
}

# Admin assignment uses the separate Connect API and the pipeline's AWS CLI.
resource "terraform_data" "admin_assignment" {
  triggers_replace = {
    agent_id   = awscc_wisdom_ai_agent.survey_agent.ai_agent_id
    version    = awscc_wisdom_ai_agent_version.survey.version_number
    profile_id = data.aws_connect_security_profile.admin.security_profile_id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]

    command = <<-BASH
      set -euo pipefail

      actual_account="$(aws sts get-caller-identity \
        --query Account \
        --output text \
        --region "$AWS_REGION")"

      if [ "$actual_account" != "$EXPECTED_ACCOUNT_ID" ]; then
        echo "AWS CLI credentials do not match the Connect instance account." >&2
        exit 1
      fi

      assistant_arn="$(aws qconnect get-assistant \
        --assistant-id "$ASSISTANT_ID" \
        --region "$AWS_REGION" \
        --query 'assistant.assistantArn' \
        --output text)"

      associated_assistants="$(aws connect list-integration-associations \
        --instance-id "$INSTANCE_ID" \
        --integration-type WISDOM_ASSISTANT \
        --region "$AWS_REGION" \
        --query 'IntegrationAssociationSummaryList[].IntegrationArn' \
        --output text)"

      if ! printf '%s\n' "$associated_assistants" |
        tr '\t' '\n' |
        grep -Fxq -- "$assistant_arn"; then
        echo "The assistant is not associated with this Connect instance." >&2
        exit 1
      fi

      # Verify both identifiers before changing security-profile assignments.
      for agent_identifier in "$AI_AGENT_ID" "$AI_AGENT_ID:$AI_AGENT_VERSION"; do
        aws qconnect get-ai-agent \
          --assistant-id "$ASSISTANT_ID" \
          --ai-agent-id "$agent_identifier" \
          --region "$AWS_REGION" \
          --query 'aiAgent.aiAgentId' \
          --output text >/dev/null
      done

      for entity_arn in "$AGENT_ARN" "$AGENT_VERSION_ARN"; do
        printf 'Assigning Admin to %s\n' "$entity_arn"

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
      AWS_REGION          = local.region
      EXPECTED_ACCOUNT_ID = local.account_id
      INSTANCE_ID         = local.instance_id
      ASSISTANT_ID        = var.assistant_id
      AI_AGENT_ID         = awscc_wisdom_ai_agent.survey_agent.ai_agent_id
      AI_AGENT_VERSION    = tostring(awscc_wisdom_ai_agent_version.survey.version_number)
      AGENT_ARN           = local.agent_arn
      AGENT_VERSION_ARN   = local.agent_version_arn

      SECURITY_PROFILES = jsonencode([
        {
          Id = data.aws_connect_security_profile.admin.security_profile_id
        }
      ])

      AWS_PAGER           = ""
      AWS_CLI_AUTO_PROMPT = "off"
    }
  }
}
