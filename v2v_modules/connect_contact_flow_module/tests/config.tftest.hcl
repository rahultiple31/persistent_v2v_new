mock_provider "aws" {}

variables {
  instance_arn           = "arn:aws:connect:us-east-1:518902362956:instance/11111111-1111-4111-8111-111111111111"
  name                   = "VMX3_MAIN_VM_MODULE_BTSGSD-DEV-US-EAST-1"
  content_file           = "../../environments/v2v/metadata/contact-flow-modules/VMX3_Main_VM_Module_btsgsd-dev-us-east-1.json"
  voicemail_queue_arn    = "arn:aws:connect:us-east-1:518902362956:instance/11111111-1111-4111-8111-111111111111/queue/22222222-2222-4222-8222-222222222222"
  beep_prompt_arn        = "arn:aws:connect:us-east-1:518902362956:instance/11111111-1111-4111-8111-111111111111/prompt/33333333-3333-4333-8333-333333333333"
  survey_data_table_id   = "44444444-4444-4444-8444-444444444444"
  timestamper_lambda_arn = "arn:aws:lambda:us-east-1:518902362956:function:mock-vmx3-timestamper"
  tags                   = { Environment = "v2v" }
}

run "renders_target_references_and_preserves_flow" {
  command = apply

  assert {
    condition = (
      aws_connect_contact_flow_module.this.name == var.name &&
      aws_connect_contact_flow_module.this.instance_id == "11111111-1111-4111-8111-111111111111" &&
      jsondecode(aws_connect_contact_flow_module.this.content).Metadata.name == var.name &&
      jsondecode(aws_connect_contact_flow_module.this.content).Version == "2019-10-30" &&
      jsondecode(aws_connect_contact_flow_module.this.content).StartAction == "Turn on flow logging." &&
      length(jsondecode(aws_connect_contact_flow_module.this.content).Actions) == 19 &&
      jsondecode(aws_connect_contact_flow_module.this.content).Settings == jsondecode(file(var.content_file)).Settings &&
      alltrue([
        for index, action in jsondecode(aws_connect_contact_flow_module.this.content).Actions :
        action.Identifier == jsondecode(file(var.content_file)).Actions[index].Identifier &&
        action.Type == jsondecode(file(var.content_file)).Actions[index].Type &&
        action.Transitions == jsondecode(file(var.content_file)).Actions[index].Transitions
      ])
    )
    error_message = "The target module must preserve all supplied actions, transitions, entry point and settings."
  }

  assert {
    condition = (
      one([for action in jsondecode(aws_connect_contact_flow_module.this.content).Actions : action if action.Type == "UpdateContactTargetQueue"]).Parameters.QueueId == var.voicemail_queue_arn &&
      one([for action in jsondecode(aws_connect_contact_flow_module.this.content).Actions : action if action.Identifier == "Play the start recording beep using SSML"]).Parameters.PromptId == var.beep_prompt_arn &&
      one([for action in jsondecode(aws_connect_contact_flow_module.this.content).Actions : action if action.Type == "EvaluateDataTableValues"]).Parameters.DataTableId == var.survey_data_table_id &&
      one([for action in jsondecode(aws_connect_contact_flow_module.this.content).Actions : action if action.Identifier == "Set Timestamp Function"]).Parameters.FlowAttributes.vmx3_timestamper_function.Value == var.timestamper_lambda_arn &&
      one([for action in jsondecode(aws_connect_contact_flow_module.this.content).Actions : action if action.Type == "InvokeLambdaFunction"]).Parameters.LambdaFunctionARN == "$.FlowAttributes.vmx3_timestamper_function" &&
      !strcontains(aws_connect_contact_flow_module.this.content, "0cc3e955-8cdd-4a82-b6fe-7593e1674ffa") &&
      !strcontains(aws_connect_contact_flow_module.this.content, "41573eb0-ae92-4b8a-bbe2-e4a32fb84801") &&
      !strcontains(aws_connect_contact_flow_module.this.content, "VMX3-VoicemailTimestamper-abbvie-sd-contactcenter-dev-us")
    )
    error_message = "All four source-environment references must be replaced without changing dynamic timestamp invocation."
  }

  assert {
    condition = (
      aws_lambda_permission.connect_timestamper.action == "lambda:InvokeFunction" &&
      aws_lambda_permission.connect_timestamper.principal == "connect.amazonaws.com" &&
      aws_lambda_permission.connect_timestamper.function_name == var.timestamper_lambda_arn &&
      aws_lambda_permission.connect_timestamper.source_arn == var.instance_arn &&
      aws_lambda_permission.connect_timestamper.source_account == "518902362956" &&
      aws_lambda_permission.connect_timestamper.qualifier == null &&
      aws_connect_lambda_function_association.timestamper.instance_id == "11111111-1111-4111-8111-111111111111" &&
      aws_connect_lambda_function_association.timestamper.function_arn == var.timestamper_lambda_arn
    )
    error_message = "Only the selected Connect instance may invoke the configured timestamper, and the function must be associated with that instance."
  }
}

run "rejects_queue_from_another_instance" {
  command = plan
  variables {
    voicemail_queue_arn = "arn:aws:connect:us-east-1:518902362956:instance/99999999-9999-4999-8999-999999999999/queue/22222222-2222-4222-8222-222222222222"
  }
  expect_failures = [aws_connect_contact_flow_module.this]
}

run "rejects_prompt_from_another_instance" {
  command = plan
  variables {
    beep_prompt_arn = "arn:aws:connect:us-east-1:518902362956:instance/99999999-9999-4999-8999-999999999999/prompt/33333333-3333-4333-8333-333333333333"
  }
  expect_failures = [aws_connect_contact_flow_module.this]
}

run "rejects_qualified_timestamper" {
  command = plan
  variables {
    timestamper_lambda_arn = "arn:aws:lambda:us-east-1:518902362956:function:mock-vmx3-timestamper:1"
  }
  expect_failures = [var.timestamper_lambda_arn]
}
