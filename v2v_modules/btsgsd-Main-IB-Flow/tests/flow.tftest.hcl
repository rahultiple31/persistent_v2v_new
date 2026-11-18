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
    ai_assistant_arn              = "arn:aws:wisdom:us-east-1:518902362956:assistant/e36d6b86-c3f5-4d6d-b85b-e44f7e7ec04f"
    ai_agent_version_arn          = "arn:aws:wisdom:us-east-1:518902362956:ai-agent/e36d6b86-c3f5-4d6d-b85b-e44f7e7ec04f/77777777-7777-7777-7777-777777777777:3"
    it_support_bot_alias_arn      = "arn:aws:lex:us-east-1:518902362956:bot-alias/V2VBOT1234/V2VALIAS12"
  }
}

run "main_inbound_uses_v2v_dependencies" {
  command = plan

  assert {
    condition = (
      aws_connect_contact_flow.this.name == "BTSGSD-V2V-US-Main-IB-Flow" &&
      aws_connect_contact_flow.this.instance_id == "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" &&
      jsondecode(aws_connect_contact_flow.this.content).Metadata.name == "BTSGSD-V2V-US-Main-IB-Flow" &&
      length(jsondecode(aws_connect_contact_flow.this.content).Actions) == 86 &&
      jsondecode(aws_connect_contact_flow.this.content).StartAction == local.main_ib_source.StartAction &&
      alltrue([
        for i, action in jsondecode(aws_connect_contact_flow.this.content).Actions :
        action.Identifier == local.main_ib_source.Actions[i].Identifier &&
        action.Type == local.main_ib_source.Actions[i].Type &&
        jsonencode(action.Transitions) == jsonencode(local.main_ib_source.Actions[i].Transitions)
      ])
    )
    error_message = "Create the requested flow in Dev and preserve all 86 actions and transitions."
  }

  assert {
    condition = (
      alltrue([
        for identifier in keys(local.main_ib_parameter_overrides) :
        contains([for action in local.main_ib_source.Actions : action.Identifier], identifier)
      ]) &&
      alltrue(flatten([
        for action in jsondecode(aws_connect_contact_flow.this.content).Actions : [
          for parameter, expected in try(local.main_ib_parameter_overrides[action.Identifier], {}) :
          jsonencode(action.Parameters[parameter]) == jsonencode(expected)
        ]
      ])) &&
      length(regexall("__[A-Z_]+__", aws_connect_contact_flow.this.content)) == 0
    )
    error_message = "Every V2V resource override must match a block in the attached flow and replace its placeholder before deployment."
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

run "q_in_connect_uses_the_v2v_assistant_agent_and_bot" {
  command = plan

  assert {
    condition = (
      local.main_ib_actions["Connect assistant"].Type == "CreateWisdomSession" &&
      one([
        for action in jsondecode(aws_connect_contact_flow.this.content).Actions : action.Parameters
        if action.Identifier == "Connect assistant"
        ]) == {
        WisdomAssistantArn = var.flow_dependencies.ai_assistant_arn
        OrchestrationAIAgentConfiguration = {
          AgentAssistanceAgentVersionArn = var.flow_dependencies.ai_agent_version_arn
        }
      } &&
      one([
        for action in jsondecode(aws_connect_contact_flow.this.content).Actions : action.Parameters.WisdomAssistantArn
        if action.Identifier == "Get customer input-L4Nj72lYly"
      ]) == var.flow_dependencies.ai_assistant_arn
    )
    error_message = "Both assistant sessions must use the V2V assistant and the V2V SupportAgent version."
  }

  assert {
    condition = (
      one([
        for action in jsondecode(aws_connect_contact_flow.this.content).Actions : action.Parameters.LexV2Bot.AliasArn
        if action.Identifier == "Get customer input-L4Nj72lYly-1wDKkEylWU"
      ]) == var.flow_dependencies.it_support_bot_alias_arn &&
      one([
        for action in jsondecode(aws_connect_contact_flow.this.content).Actions : action.Parameters.LexSessionAttributes["x-amz-lex:q-in-connect:ai-agent-arn"]
        if action.Identifier == "Get customer input-L4Nj72lYly-1wDKkEylWU"
      ]) == var.flow_dependencies.ai_agent_version_arn &&
      one([
        for action in jsondecode(aws_connect_contact_flow.this.content).Actions : length(action.Parameters.LexSessionAttributes)
        if action.Identifier == "Get customer input-L4Nj72lYly-1wDKkEylWU"
      ]) == length(local.main_ib_actions["Get customer input-L4Nj72lYly-1wDKkEylWU"].Parameters.LexSessionAttributes) &&
      one([
        for action in jsondecode(aws_connect_contact_flow.this.content).Actions : action.Parameters.LexSessionAttributes["x-amz-lex:q-in-connect:session-arn"]
        if action.Identifier == "Get customer input-L4Nj72lYly-1wDKkEylWU"
      ]) == "$.Wisdom.SessionArn"
    )
    error_message = "The Lex block must call the V2V IT Support alias with the V2V agent, keeping every other session attribute."
  }

  assert {
    condition = (
      jsondecode(aws_connect_contact_flow.this.content).Metadata.ActionMetadata["Get customer input-L4Nj72lYly"].aiAgentVersionArn == var.flow_dependencies.ai_agent_version_arn &&
      jsondecode(aws_connect_contact_flow.this.content).Metadata.ActionMetadata["Get customer input-L4Nj72lYly"].parameters.WisdomAssistantArn.aiAgentVersionArn == var.flow_dependencies.ai_agent_version_arn &&
      jsondecode(aws_connect_contact_flow.this.content).Metadata.ActionMetadata["b69a2aad-6fef-4349-a839-e1fbf206f2d3"].contactFlow.id == var.flow_dependencies.customer_queue_flow_arn &&
      jsondecode(aws_connect_contact_flow.this.content).Metadata.ActionMetadata["d9899688-e08c-4865-a827-2d22da50eb82"].contactFlow.id == var.flow_dependencies.survey_flow_arn &&
      jsondecode(aws_connect_contact_flow.this.content).Metadata.ActionMetadata["b69a2aad-6fef-4349-a839-e1fbf206f2d3"].position == local.main_ib_source.Metadata.ActionMetadata["b69a2aad-6fef-4349-a839-e1fbf206f2d3"].position
    )
    error_message = "Console metadata must show the V2V agent version and V2V event-hook flows and keep its layout."
  }

  assert {
    condition = (
      length(local.main_ib_source_ids) == 4 &&
      alltrue([for id in local.main_ib_source_ids : strcontains(file("${path.module}/assets/BTSGSD-Main-IB-Flow.json"), id)]) &&
      !anytrue([for id in local.main_ib_source_ids : strcontains(aws_connect_contact_flow.this.content, id)])
    )
    error_message = "The dev assistant, agent, Lex bot and instance IDs from the export must not survive in the V2V flow."
  }
}

run "reject_agent_from_another_assistant" {
  command = plan

  variables {
    flow_dependencies = merge(var.flow_dependencies, {
      ai_agent_version_arn = "arn:aws:wisdom:us-east-1:518902362956:ai-agent/bc274e3f-380d-45e7-968f-2d19f92acd74/c1c0c6cf-2e49-4091-bb06-85f9e7095a96:42"
    })
  }

  expect_failures = [var.flow_dependencies]
}

run "reject_unversioned_agent" {
  command = plan

  variables {
    flow_dependencies = merge(var.flow_dependencies, {
      ai_agent_version_arn = "arn:aws:wisdom:us-east-1:518902362956:ai-agent/e36d6b86-c3f5-4d6d-b85b-e44f7e7ec04f/77777777-7777-7777-7777-777777777777"
    })
  }

  expect_failures = [var.flow_dependencies]
}
