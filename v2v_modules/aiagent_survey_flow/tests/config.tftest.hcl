mock_provider "aws" {}
mock_provider "external" {}

variables {
  settings = {
    instance_arn             = "arn:aws:connect:us-east-1:518902362956:instance/bcc989e5-cd9d-494f-9cd4-434f39ccc90e"
    expected_instance_arn    = "arn:aws:connect:us-east-1:518902362956:instance/bcc989e5-cd9d-494f-9cd4-434f39ccc90e"
    survey_data_table_id     = "11111111-1111-4111-8111-111111111111"
    timestamper_lambda_arn   = "arn:aws:lambda:us-east-1:518902362956:function:test-v2v-timestamper"
    yesno_bot_alias_arn      = "arn:aws:lex:us-east-1:518902362956:bot-alias/TESTBOT123/TESTALIAS1"
    voicemail_flow_module_id = "22222222-2222-4222-8222-222222222222"
  }
}

run "survey_preserves_graph_and_uses_v2v_dependencies" {
  command = plan

  assert {
    condition = (
      module.flow.flow_name == "BTSGSD-V2V-US-SurveyFlow" &&
      jsondecode(local.survey_flow_content).Metadata.name == module.flow.flow_name &&
      length(jsondecode(local.survey_flow_content).Actions) == 43 &&
      jsondecode(local.survey_flow_content).StartAction == local.survey_flow_source.StartAction &&
      alltrue([
        for i, action in jsondecode(local.survey_flow_content).Actions :
        action.Identifier == local.survey_flow_source.Actions[i].Identifier &&
        action.Type == local.survey_flow_source.Actions[i].Type &&
        jsonencode(action.Transitions) == jsonencode(local.survey_flow_source.Actions[i].Transitions)
      ])
    )
    error_message = "Preserve all 43 survey actions and transitions in the named V2V flow."
  }

  assert {
    condition = (
      length(regexall("__.+?__", local.survey_flow_content)) == 0 &&
      alltrue([
        for action in jsondecode(local.survey_flow_content).Actions :
        try(action.Parameters.LexV2Bot.AliasArn == var.settings.yesno_bot_alias_arn, true)
      ]) &&
      length([
        for action in jsondecode(local.survey_flow_content).Actions : action
        if action.Type == "ConnectParticipantWithLexBot"
      ]) == 4 &&
      one([
        for action in jsondecode(local.survey_flow_content).Actions : action.Parameters.DataTableId
        if action.Type == "EvaluateDataTableValues"
      ]) == var.settings.survey_data_table_id &&
      one([
        for action in jsondecode(local.survey_flow_content).Actions : action.Parameters.LambdaFunctionARN
        if action.Type == "InvokeLambdaFunction"
      ]) == var.settings.timestamper_lambda_arn &&
      one([
        for action in jsondecode(local.survey_flow_content).Actions : action.Parameters.FlowModuleId
        if action.Type == "InvokeFlowModule"
      ]) == "${var.settings.voicemail_flow_module_id}:$LATEST"
    )
    error_message = "Resolve the four Yes/No blocks, survey table, timestamper, and voicemail module without source IDs or placeholders."
  }
}

run "survey_rejects_a_connect_arn_as_the_lex_alias" {
  command = plan

  variables {
    settings = {
      instance_arn             = "arn:aws:connect:us-east-1:518902362956:instance/bcc989e5-cd9d-494f-9cd4-434f39ccc90e"
      survey_data_table_id     = "11111111-1111-4111-8111-111111111111"
      timestamper_lambda_arn   = "arn:aws:lambda:us-east-1:518902362956:function:test-v2v-timestamper"
      yesno_bot_alias_arn      = "arn:aws:connect:us-east-1:518902362956:instance/bcc989e5-cd9d-494f-9cd4-434f39ccc90e"
      voicemail_flow_module_id = "22222222-2222-4222-8222-222222222222"
    }
  }

  expect_failures = [var.settings]
}
