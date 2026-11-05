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
  }

  main_ib_content = jsonencode(merge(local.main_ib_source, {
    Metadata = merge(local.main_ib_source.Metadata, {
      name = "BTSGSD-V2V-US-Main-IB-Flow"
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
  }
}

