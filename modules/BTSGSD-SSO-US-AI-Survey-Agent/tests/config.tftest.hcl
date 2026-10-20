mock_provider "aws" {
  mock_data "aws_region" {
    defaults = {
      region = "us-east-1"
    }
  }

  mock_data "aws_connect_security_profile" {
    defaults = {
      security_profile_id = "33333333-3333-3333-3333-333333333333"
    }
  }

  mock_resource "aws_cloudformation_stack" {
    defaults = {
      outputs = {
        AgentId        = "44444444-4444-4444-4444-444444444444"
        AgentArn       = "arn:aws:wisdom:us-east-1:210987654321:ai-agent/11111111-1111-1111-1111-111111111111/44444444-4444-4444-4444-444444444444"
        AgentVersionId = "44444444-4444-4444-4444-444444444444:3"
      }
    }
  }
}

variables {
  assistant_id            = "11111111-1111-1111-1111-111111111111"
  orchestration_prompt_id = "22222222-2222-2222-2222-222222222222:2"
  connect_instance_arn    = "arn:aws:connect:us-east-1:210987654321:instance/55555555-5555-5555-5555-555555555555"
}

run "survey_agent_configuration" {
  command = plan

  assert {
    condition = (
      jsondecode(aws_cloudformation_stack.survey.template_body).Resources.SurveyAgent.Properties.Name == "BTSGSD-SSO-US-AI-Survey-Agent" &&
      jsondecode(aws_cloudformation_stack.survey.template_body).Resources.SurveyAgent.Properties.Type == "ORCHESTRATION" &&
      jsondecode(aws_cloudformation_stack.survey.template_body).Resources.SurveyAgent.Properties.AssistantId == var.assistant_id &&
      jsondecode(aws_cloudformation_stack.survey.template_body).Resources.SurveyAgent.Properties.Configuration.OrchestrationAIAgentConfiguration.ConnectInstanceArn == var.connect_instance_arn &&
      jsondecode(aws_cloudformation_stack.survey.template_body).Resources.SurveyAgent.Properties.Configuration.OrchestrationAIAgentConfiguration.Locale == "en_US" &&
      jsondecode(aws_cloudformation_stack.survey.template_body).Resources.SurveyAgent.Properties.Configuration.OrchestrationAIAgentConfiguration.OrchestrationAIPromptId == var.orchestration_prompt_id
    )
    error_message = "Create the named English US orchestration agent in the existing instance and assistant."
  }

  assert {
    condition = (
      length(local.tools) == 2 &&
      alltrue([for tool in local.tools : tool.ToolType == "RETURN_TO_CONTROL"]) &&
      local.tools[0].ToolName == "UpdateLanguage" &&
      local.tools[0].InputSchema.required == ["LanguageDetected"] &&
      local.tools[0].InputSchema.properties.LanguageDetected.type == "string" &&
      strcontains(local.tools[0].Instruction.Instruction, "If a value was not collected, leave it blank.") &&
      local.tools[1].ToolName == "UpdateSurveyResults" &&
      toset(local.tools[1].InputSchema.required) == toset(["SurveyIntent", "SurveyQ1", "SurveyQ2", "SurveyQ3"]) &&
      alltrue([for property in local.tools[1].InputSchema.properties : property.type == "string"]) &&
      strcontains(local.tools[1].Instruction.Instruction, "wantToleaveRecommendation") &&
      alltrue([for tool in local.tools : strcontains(tool.Instruction.Instruction, "return control to the contact flow.")])
    )
    error_message = "Keep both Return of Control tools with the requested required fields and instructions."
  }

  assert {
    condition = (
      data.aws_connect_security_profile.admin.name == "Admin" &&
      data.aws_connect_security_profile.admin.instance_id == "55555555-5555-5555-5555-555555555555" &&
      jsondecode(aws_cloudformation_stack.survey.template_body).Resources.SurveyAgentVersion.Properties.ModifiedTimeSeconds["Fn::GetAtt"] == ["SurveyAgent", "ModifiedTimeSeconds"]
    )
    error_message = "Look up Admin in this instance and publish a new agent version when configuration changes."
  }
}
