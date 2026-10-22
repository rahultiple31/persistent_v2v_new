mock_provider "aws" {
  mock_data "aws_lambda_function" {
    defaults = {
      function_name = "SNOW_Abbvie"
      arn           = "arn:aws:lambda:us-east-1:518902362956:function:SNOW_Abbvie"
    }
  }
  mock_data "aws_connect_queue" {
    defaults = {
      arn = "arn:aws:connect:us-east-1:518902362956:instance/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/queue/22222222-2222-2222-2222-222222222222"
    }
  }
}

variables {
  instance_arn = "arn:aws:connect:us-east-1:518902362956:instance/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  flow_json    = file("../../environments/v2v/metadata/contact-flows/BTSGSD-Main-IB-Flow.json")
  flow_dependencies = {
    us_queue_arn                  = "arn:aws:connect:us-east-1:518902362956:instance/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/queue/44444444-4444-4444-4444-444444444444"
    customer_queue_flow_arn       = "arn:aws:connect:us-east-1:518902362956:instance/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/contact-flow/33333333-3333-3333-3333-333333333333"
    survey_flow_arn               = "arn:aws:connect:us-east-1:518902362956:instance/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/contact-flow/66666666-6666-6666-6666-666666666666"
    agent_ui_flow_arn             = "arn:aws:connect:us-east-1:518902362956:instance/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/contact-flow/55555555-5555-5555-5555-555555555555"
    language_table_id             = "11111111-1111-1111-1111-111111111111"
    survey_table_id               = "22222222-2222-2222-2222-222222222222"
    blocker_table_id              = "33333333-3333-3333-3333-333333333333"
    session_attributes_lambda_arn = "arn:aws:lambda:us-east-1:518902362956:function:BTSGSD-V2V-US-UpdateSessionAttributes"
    silence_guard_lambda_arn      = "arn:aws:lambda:us-east-1:518902362956:function:BTSGSD-V2V-US-silence_guard"
    queue_metrics_lambda_arn      = "arn:aws:lambda:us-east-1:518902362956:function:BTSGSD-V2V-US-conversionOfQueueMetrics"
  }
}

run "main_inbound_uses_v2v_dependencies" {
  command = plan

  assert {
    condition = (
      aws_connect_contact_flow.this.name == "BTSGSD-V2V-US-Main-IB-Flow" &&
      aws_connect_contact_flow.this.instance_id == "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" &&
      jsondecode(aws_connect_contact_flow.this.content).Metadata.name == "BTSGSD-V2V-US-Main-IB-Flow" &&
      length(jsondecode(aws_connect_contact_flow.this.content).Actions) == 65 &&
      jsondecode(aws_connect_contact_flow.this.content).StartAction == local.main_ib_source.StartAction &&
      alltrue([
        for i, action in jsondecode(aws_connect_contact_flow.this.content).Actions :
        action.Identifier == local.main_ib_source.Actions[i].Identifier &&
        action.Type == local.main_ib_source.Actions[i].Type &&
        jsonencode(action.Transitions) == jsonencode(local.main_ib_source.Actions[i].Transitions)
      ])
    )
    error_message = "Create the requested flow in Dev and preserve all 65 actions and transitions."
  }

  assert {
    condition = alltrue([
      for action in jsondecode(aws_connect_contact_flow.this.content).Actions :
      !strcontains(jsonencode(action.Parameters), "0cc3e955-8cdd-4a82-b6fe-7593e1674ffa")
      ]) && alltrue([
      for action in jsondecode(aws_connect_contact_flow.this.content).Actions :
      action.Parameters.QueueId == var.flow_dependencies.us_queue_arn
      if action.Identifier == "Escalate"
      ]) && alltrue([
      for action in jsondecode(aws_connect_contact_flow.this.content).Actions :
      action.Parameters.QueueId == data.aws_connect_queue.latam.arn &&
      action.Parameters.QueueId != var.flow_dependencies.us_queue_arn
      if action.Identifier == "LATAM_Queue"
    ])
    error_message = "Remove old-instance runtime references and keep LATAM routing separate from the Dev US queue."
  }

  assert {
    condition = (
      alltrue([
        for action in jsondecode(aws_connect_contact_flow.this.content).Actions :
        action.Parameters.LambdaFunctionARN == var.flow_dependencies.session_attributes_lambda_arn
        if action.Identifier == "Update session data"
      ]) &&
      aws_lambda_permission.phone_lookup.principal == "connect.amazonaws.com" &&
      aws_lambda_permission.phone_lookup.source_arn == var.instance_arn &&
      aws_connect_lambda_function_association.phone_lookup.function_arn == data.aws_lambda_function.phone_lookup.arn
    )
    error_message = "Use the Dev session Lambda and grant and associate the existing phone lookup Lambda with Dev Connect."
  }
}

