# Contact flow and flow module copied from the SSO instance
# (btsgsd-dev-us-east-1, c227a737-...). SSO-specific references are replaced
# with the target instance's resources; preconditions reject any leftovers.

locals {
  sso_instance_id = "c227a737-3e4f-4c64-8397-2d37e318801d"
  sso_base_arn    = "arn:aws:connect:us-east-1:518902362956:instance/${local.sso_instance_id}"

  # Known at plan time so the rendered module content can be reviewed.
  timestamper_function_arn = "arn:${local.partition}:lambda:${local.region}:${local.account_id}:function:${local.function_names["VoicemailTimestamper"]}"

  task_flow_name   = "${var.name_prefix}-VMX3_Basic_Task_Flow"
  flow_module_name = "${var.name_prefix}-VMX3_Main_VM_Module"

  # References exported from the SSO instance.
  sso_customer_queue_flow_arn = "${local.sso_base_arn}/contact-flow/017c14ad-7e10-46c7-85ac-2ef820de24be"
  sso_voicemail_queue_arn     = "${local.sso_base_arn}/queue/713f62d2-6348-45ad-988a-bb6f1ef221b1"
  sso_beep_prompt_arn         = "${local.sso_base_arn}/prompt/013f3d08-8171-4bb2-a93b-80f895e008db"
  sso_data_table_id           = "0c2359aa-9062-43ec-9d0d-abc5861c2197"
  sso_timestamper_arn         = "arn:aws:lambda:us-east-1:518902362956:function:VMX3-VoicemailTimestamper-abbvie-sd-contactcenter-dev-us"
  sso_queue_display_name      = "\"BTSGSD-DEV-SSO-US-VM-QUEUE\""
  sso_table_display_name      = "\"BTSGSD-Survey-DataTable\""

  task_flow_content = jsonencode(jsondecode(replace(
    file("${path.module}/assets/VMX3_Basic_Task_Flow.json"),
    local.sso_customer_queue_flow_arn,
    data.aws_connect_contact_flow.customer_queue.arn
  )))

  # Queue ARN appears in both UpdateContactTargetQueue and the vmx3_queue_arn attribute.
  flow_module_content = jsonencode(jsondecode(
    replace(replace(replace(replace(replace(replace(
      file("${path.module}/assets/VMX3_Main_VM_Module.json"),
      local.sso_voicemail_queue_arn, var.voicemail_queue_arn),
      local.sso_beep_prompt_arn, var.beep_prompt_arn),
      local.sso_data_table_id, var.prompt_data_table_id),
      local.sso_timestamper_arn, local.timestamper_function_arn),
      local.sso_queue_display_name, jsonencode(var.voicemail_queue_name)),
      local.sso_table_display_name, jsonencode(var.prompt_data_table_name)
    )
  ))
}

data "aws_connect_contact_flow" "customer_queue" {
  instance_id = local.instance_id
  name        = var.customer_queue_flow_name
}

# Timestamper is invoked by the flow module.
resource "aws_lambda_permission" "connect_timestamper" {
  statement_id   = "AllowConnect-${local.instance_id}"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.this["VoicemailTimestamper"].function_name
  principal      = "connect.amazonaws.com"
  source_account = local.account_id
  source_arn     = var.instance_arn
}

resource "aws_connect_lambda_function_association" "timestamper" {
  instance_id  = local.instance_id
  function_arn = aws_lambda_function.this["VoicemailTimestamper"].arn

  depends_on = [aws_lambda_permission.connect_timestamper]
}

# Task flow started by the Packager for each voicemail.
resource "aws_connect_contact_flow" "task" {
  instance_id = local.instance_id
  name        = local.task_flow_name
  description = "Sample basic task flow for voicemail."
  type        = "CONTACT_FLOW"
  content     = local.task_flow_content
  tags        = merge(var.tags, { Name = local.task_flow_name })

  lifecycle {
    precondition {
      condition     = !strcontains(local.task_flow_content, local.sso_instance_id)
      error_message = "The task flow still references the SSO instance."
    }
  }
}

resource "aws_connect_contact_flow_module" "main" {
  instance_id = local.instance_id
  name        = local.flow_module_name
  description = "Core contact flow module that records the voicemail. Intended to be called from other contact flows. Please make sure that all required attributes for your voicemail delivery model are set prior to invoking this flow."
  content     = local.flow_module_content
  tags        = merge(var.tags, { Name = local.flow_module_name })

  lifecycle {
    precondition {
      condition     = !strcontains(local.flow_module_content, local.sso_instance_id)
      error_message = "The flow module still references the SSO instance."
    }
    precondition {
      condition     = !strcontains(local.flow_module_content, "abbvie-sd-contactcenter")
      error_message = "The flow module still references the abbvie-sd-contactcenter timestamper."
    }
    precondition {
      condition     = startswith(var.voicemail_queue_arn, "${var.instance_arn}/queue/")
      error_message = "The voicemail queue must belong to the target Connect instance."
    }
    precondition {
      condition     = startswith(var.beep_prompt_arn, "${var.instance_arn}/prompt/")
      error_message = "The beep prompt must belong to the target Connect instance."
    }
  }

  depends_on = [aws_connect_lambda_function_association.timestamper]
}
