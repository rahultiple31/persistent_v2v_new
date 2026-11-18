locals {
  instance_id = split("/", var.instance_arn)[1]
}

data "aws_connect_queue" "latam" {
  instance_id = local.instance_id
  name        = var.latam_queue_name
}

data "aws_lambda_function" "phone_lookup" {
  function_name = var.phone_lookup_function_name
}

resource "aws_lambda_permission" "phone_lookup" {
  statement_id  = "AllowConnectMainInboundPhoneLookup-${local.instance_id}"
  action        = "lambda:InvokeFunction"
  function_name = data.aws_lambda_function.phone_lookup.function_name
  principal     = "connect.amazonaws.com"

  source_arn     = var.instance_arn
  source_account = split(":", var.instance_arn)[4]
}

resource "aws_connect_lambda_function_association" "phone_lookup" {
  instance_id  = local.instance_id
  function_arn = data.aws_lambda_function.phone_lookup.arn

  depends_on = [aws_lambda_permission.phone_lookup]
}

locals {
  main_ib_source = jsondecode(
    file("${path.module}/assets/BTSGSD-Main-IB-Flow.json")
  )

  # Override only resource references; retain the supplied graph and parameters.
  main_ib_parameter_overrides = {
    "Escalate" = {
      QueueId = var.flow_dependencies.us_queue_arn
    }
    "LATAM_Queue" = {
      QueueId = data.aws_connect_queue.latam.arn
    }
    "Survey FLow" = {
      ContactFlowId = var.flow_dependencies.survey_flow_arn
    }
    "b69a2aad-6fef-4349-a839-e1fbf206f2d3" = {
      EventHooks = {
        CustomerQueue = var.flow_dependencies.customer_queue_flow_arn
      }
    }
    "d9899688-e08c-4865-a827-2d22da50eb82" = {
      EventHooks = {
        CustomerRemaining = var.flow_dependencies.survey_flow_arn
      }
    }
    "ff4ce28b-f76a-430a-ba3f-b5bf60cdfb94" = {
      EventHooks = {
        DefaultAgentUI = var.flow_dependencies.agent_ui_flow_arn
      }
    }
    "Load lang config" = {
      DataTableId = var.flow_dependencies.language_table_id
    }
    "430a3acf-25ed-45c4-bcd5-4741bb2c619c" = {
      DataTableId = var.flow_dependencies.survey_table_id
    }
    "TopLevelBlocker_Message" = {
      DataTableId = var.flow_dependencies.blocker_table_id
    }
    "Phone_Lookup" = {
      LambdaFunctionARN = data.aws_lambda_function.phone_lookup.arn
    }
    "Update session data" = {
      LambdaFunctionARN = var.flow_dependencies.session_attributes_lambda_arn
    }
    "Guard_Lambda_Complete" = {
      LambdaFunctionARN = var.flow_dependencies.silence_guard_lambda_arn
    }
    "Guard_Lambda_Escalate" = {
      LambdaFunctionARN = var.flow_dependencies.silence_guard_lambda_arn
    }
    "0323e84a-b89e-466c-bd65-aa96cf580f9d" = {
      LambdaFunctionARN = var.flow_dependencies.queue_metrics_lambda_arn
    }
    # Q in Connect: the V2V assistant, SupportAgent version and IT Support bot.
    "Get customer input-L4Nj72lYly" = {
      WisdomAssistantArn = var.flow_dependencies.ai_assistant_arn
    }
    "Connect assistant" = {
      WisdomAssistantArn = var.flow_dependencies.ai_assistant_arn
      OrchestrationAIAgentConfiguration = merge(
        local.main_ib_actions["Connect assistant"].Parameters.OrchestrationAIAgentConfiguration,
        { AgentAssistanceAgentVersionArn = var.flow_dependencies.ai_agent_version_arn }
      )
    }
    "Get customer input-L4Nj72lYly-1wDKkEylWU" = {
      LexV2Bot = merge(
        local.main_ib_actions["Get customer input-L4Nj72lYly-1wDKkEylWU"].Parameters.LexV2Bot,
        { AliasArn = var.flow_dependencies.it_support_bot_alias_arn }
      )
      LexSessionAttributes = merge(
        local.main_ib_actions["Get customer input-L4Nj72lYly-1wDKkEylWU"].Parameters.LexSessionAttributes,
        { "x-amz-lex:q-in-connect:ai-agent-arn" = var.flow_dependencies.ai_agent_version_arn }
      )
    }
  }

  main_ib_actions = { for action in local.main_ib_source.Actions : action.Identifier => action }

  # Dev IDs read from the export itself: its assistant, AI agent, Lex bot and
  # Connect instance. None may remain in the rendered V2V flow.
  main_ib_source_ids = distinct([
    element(split("/", local.main_ib_actions["Connect assistant"].Parameters.WisdomAssistantArn), 1),
    element(split("/", split(":", local.main_ib_actions["Connect assistant"].Parameters.OrchestrationAIAgentConfiguration.AgentAssistanceAgentVersionArn)[5]), 2),
    element(split("/", local.main_ib_actions["Get customer input-L4Nj72lYly-1wDKkEylWU"].Parameters.LexV2Bot.AliasArn), 1),
    element(split("/", local.main_ib_source.Metadata.ActionMetadata["b69a2aad-6fef-4349-a839-e1fbf206f2d3"].contactFlow.id), 1),
  ])

  # Console metadata (display only) that names the dev agent version and the
  # dev event-hook flows; keep it in line with the parameters above.
  main_ib_metadata_overrides = {
    "Get customer input-L4Nj72lYly" = {
      aiAgentVersionArn = var.flow_dependencies.ai_agent_version_arn
      parameters = merge(
        local.main_ib_source.Metadata.ActionMetadata["Get customer input-L4Nj72lYly"].parameters,
        {
          WisdomAssistantArn = merge(
            local.main_ib_source.Metadata.ActionMetadata["Get customer input-L4Nj72lYly"].parameters.WisdomAssistantArn,
            { aiAgentVersionArn = var.flow_dependencies.ai_agent_version_arn }
          )
        }
      )
    }
    "b69a2aad-6fef-4349-a839-e1fbf206f2d3" = {
      contactFlow = merge(
        local.main_ib_source.Metadata.ActionMetadata["b69a2aad-6fef-4349-a839-e1fbf206f2d3"].contactFlow,
        { id = var.flow_dependencies.customer_queue_flow_arn }
      )
    }
    "d9899688-e08c-4865-a827-2d22da50eb82" = {
      contactFlow = merge(
        local.main_ib_source.Metadata.ActionMetadata["d9899688-e08c-4865-a827-2d22da50eb82"].contactFlow,
        { id = var.flow_dependencies.survey_flow_arn }
      )
    }
  }

  main_ib_content = jsonencode(merge(local.main_ib_source, {
    Metadata = merge(local.main_ib_source.Metadata, {
      name = "BTSGSD-V2V-US-Main-IB-Flow"
      ActionMetadata = merge(local.main_ib_source.Metadata.ActionMetadata, {
        for identifier, override in local.main_ib_metadata_overrides :
        identifier => merge(local.main_ib_source.Metadata.ActionMetadata[identifier], override)
      })
    })
    Actions = [
      for action in local.main_ib_source.Actions : merge(action, {
        Parameters = merge(action.Parameters, try(local.main_ib_parameter_overrides[action.Identifier], {}))
      })
    ]
  }))
}

resource "aws_connect_contact_flow" "this" {
  instance_id = local.instance_id
  name        = "BTSGSD-V2V-US-Main-IB-Flow"
  description = "Main inbound flow for the V2V Connect instance."
  type        = "CONTACT_FLOW"
  content     = local.main_ib_content

  tags = merge(var.tags, {
    Name = "BTSGSD-V2V-US-Main-IB-Flow"
  })

  depends_on = [
    aws_connect_lambda_function_association.phone_lookup
  ]

  lifecycle {
    prevent_destroy = true

    precondition {
      condition     = var.expected_instance_arn == null ? true : var.instance_arn == var.expected_instance_arn
      error_message = "Deploy the main inbound flow only to the selected V2V Connect instance."
    }
    precondition {
      condition = !anytrue([
        for id in local.main_ib_source_ids : strcontains(local.main_ib_content, id)
      ])
      error_message = "The rendered flow still references a dev-only instance, assistant, agent or Lex bot."
    }
  }
}

