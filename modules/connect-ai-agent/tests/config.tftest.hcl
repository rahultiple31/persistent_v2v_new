mock_provider "aws" {
  mock_data "aws_connect_security_profile" {
    defaults = {
      security_profile_id = "33333333-3333-3333-3333-333333333333"
    }
  }
}

mock_provider "awscc" {}

variables {
  assistant_id            = "11111111-1111-1111-1111-111111111111"
  orchestration_prompt_id = "22222222-2222-2222-2222-222222222222:2"
  connect_instance_arn    = "arn:aws:connect:us-east-1:210987654321:instance/55555555-5555-5555-5555-555555555555"
}

run "survey_agent_configuration" {
  command = plan

  assert {
    condition = (
      awscc_wisdom_ai_agent.survey_agent.name == "BTSGSD-SSO-US-AI-Survey-Agent" &&
      awscc_wisdom_ai_agent.survey_agent.type == "ORCHESTRATION" &&
      awscc_wisdom_ai_agent.survey_agent.assistant_id == var.assistant_id &&
      awscc_wisdom_ai_agent.survey_agent.configuration.orchestration_ai_agent_configuration.connect_instance_arn == var.connect_instance_arn &&
      awscc_wisdom_ai_agent.survey_agent.configuration.orchestration_ai_agent_configuration.locale == "en_US" &&
      awscc_wisdom_ai_agent.survey_agent.configuration.orchestration_ai_agent_configuration.orchestration_ai_prompt_id == var.orchestration_prompt_id &&
      awscc_wisdom_ai_agent.survey_agent.tags["Env"] == "SSO" &&
      awscc_wisdom_ai_agent.survey_agent.tags["Org"] == "BTSGSD"
    )
    error_message = "Create the requested English US orchestration agent with AWSCC configuration and map-valued tags."
  }

  assert {
    condition = (
      length(awscc_wisdom_ai_agent.survey_agent.configuration.orchestration_ai_agent_configuration.tool_configurations) == 2 &&
      alltrue([
        for tool in awscc_wisdom_ai_agent.survey_agent.configuration.orchestration_ai_agent_configuration.tool_configurations :
        tool.tool_type == "RETURN_TO_CONTROL" && strcontains(tool.instruction.instruction, "return control to the contact flow.")
      ]) &&
      awscc_wisdom_ai_agent.survey_agent.configuration.orchestration_ai_agent_configuration.tool_configurations[0].tool_name == "UpdateLanguage" &&
      jsondecode(awscc_wisdom_ai_agent.survey_agent.configuration.orchestration_ai_agent_configuration.tool_configurations[0].input_schema).required == ["LanguageDetected"] &&
      awscc_wisdom_ai_agent.survey_agent.configuration.orchestration_ai_agent_configuration.tool_configurations[1].tool_name == "UpdateSurveyResults" &&
      toset(jsondecode(awscc_wisdom_ai_agent.survey_agent.configuration.orchestration_ai_agent_configuration.tool_configurations[1].input_schema).required) == toset(["SurveyIntent", "SurveyQ1", "SurveyQ2", "SurveyQ3"])
    )
    error_message = "Attach both Return of Control tools with the exact required schema fields."
  }

  assert {
    condition = (
      data.aws_connect_security_profile.admin.name == "Admin" &&
      data.aws_connect_security_profile.admin.instance_id == "55555555-5555-5555-5555-555555555555" &&
      awscc_wisdom_ai_agent_version.survey.assistant_id == var.assistant_id
    )
    error_message = "Use the existing instance's Admin profile and publish the agent under the correct assistant."
  }
}

run "unpublished_prompt_is_rejected" {
  command = plan

  variables {
    orchestration_prompt_id = "22222222-2222-2222-2222-222222222222"
  }

  expect_failures = [var.orchestration_prompt_id]
}
