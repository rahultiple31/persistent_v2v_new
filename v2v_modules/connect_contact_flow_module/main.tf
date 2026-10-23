terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

locals {
  instance_id      = split("/", var.instance_arn)[1]
  instance_account = split(":", var.instance_arn)[4]
  source_document  = jsondecode(file(var.content_file))

  rendered_content = jsonencode(merge(local.source_document, {
    Metadata = merge(local.source_document.Metadata, {
      name = var.name
    })

    Actions = [
      for action in local.source_document.Actions : merge(action, {
        Parameters = merge(
          action.Parameters,
          action.Identifier == "f2e21963-51f3-4cf1-9d51-701f9ee71b91" ? {
            QueueId = var.voicemail_queue_arn
          } : {},
          action.Identifier == "Play the start recording beep using SSML" ? {
            PromptId = var.beep_prompt_arn
          } : {},
          action.Identifier == "927d14cd-2cf5-4fe7-93f9-f3c5f1b717d5" ? {
            DataTableId = var.survey_data_table_id
          } : {},
          action.Identifier == "Set Timestamp Function" ? {
            FlowAttributes = merge(action.Parameters.FlowAttributes, {
              vmx3_timestamper_function = {
                Value = var.timestamper_lambda_arn
              }
            })
          } : {}
        )
      })
    ]
  }))
}

# The existing Lambda must return a STRING_MAP containing vmx3_timestamp.
resource "aws_lambda_permission" "connect_timestamper" {
  statement_id   = "AllowConnectVMX3-${local.instance_id}"
  action         = "lambda:InvokeFunction"
  function_name  = var.timestamper_lambda_arn
  principal      = "connect.amazonaws.com"
  source_account = local.instance_account
  source_arn     = var.instance_arn
}

resource "aws_connect_lambda_function_association" "timestamper" {
  instance_id  = local.instance_id
  function_arn = var.timestamper_lambda_arn
}

resource "aws_connect_contact_flow_module" "this" {
  instance_id = local.instance_id
  name        = var.name
  description = "Core VMX3 voicemail recording module, invoked from other contact flows."
  content     = local.rendered_content
  tags        = merge(var.tags, { Name = var.name })

  lifecycle {
    precondition {
      condition     = startswith(var.voicemail_queue_arn, "${var.instance_arn}/queue/")
      error_message = "The voicemail queue must belong to the target Connect instance."
    }
    precondition {
      condition     = startswith(var.beep_prompt_arn, "${var.instance_arn}/prompt/")
      error_message = "The beep prompt must belong to the target Connect instance."
    }
  }

  depends_on = [
    aws_lambda_permission.connect_timestamper,
    aws_connect_lambda_function_association.timestamper,
  ]
}
