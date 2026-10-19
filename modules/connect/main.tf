locals {
  service_name_prefix          = lower(replace("${var.contact_center_alias}-${var.environment}-${var.region_code}", "_", "-"))
  instance_name                = lower(replace(coalesce(var.instance_alias, "${local.service_name_prefix}-${var.service_name_suffix}"), "_", "-"))
  primary_queue_name           = "${local.service_name_prefix}-primary-queue"
  agent_security_profile_name  = "${local.service_name_prefix}-agent-security-profile"
  primary_routing_profile_name = "${local.service_name_prefix}-primary-routing-profile"
  placeholder_flow_name        = "${local.service_name_prefix}-placeholder-inbound-flow"
  customer_queue_flow_name     = "${local.service_name_prefix}-transfer-to-agent-customer-queue-flow"
  outbound_whisper_flow_name   = "${local.service_name_prefix}-outbound-whisper-flow"
  agent_transfer_flow_name     = "${local.service_name_prefix}-agent-to-agent-transfer-flow"
  hr_flow_name                 = "${local.service_name_prefix}-HR"
  tags = merge(var.common_tags, {
    Name       = local.instance_name
    RegionCode = var.region_code
    AWSRegion  = var.aws_region
    Service    = var.service_name_suffix
  })
}

resource "aws_connect_instance" "this" {
  identity_management_type = "SAML"
  inbound_calls_enabled    = true
  outbound_calls_enabled   = true
  instance_alias           = local.instance_name
  tags                     = local.tags

  lifecycle {
    precondition {
      condition     = length(local.instance_name) <= 45
      error_message = "Amazon Connect instance aliases must not exceed 45 characters."
    }
  }
}

data "aws_connect_hours_of_operation" "basic" {
  instance_id = aws_connect_instance.this.id
  name        = "Basic Hours"
}

resource "aws_connect_queue" "primary" {
  instance_id           = aws_connect_instance.this.id
  name                  = local.primary_queue_name
  description           = "Primary queue for ${upper(var.region_code)} ${var.environment} contact center."
  hours_of_operation_id = data.aws_connect_hours_of_operation.basic.hours_of_operation_id
  tags                  = merge(local.tags, { Name = local.primary_queue_name })
}

resource "aws_connect_security_profile" "agent" {
  instance_id = aws_connect_instance.this.id
  name        = local.agent_security_profile_name
  permissions = [
    "BasicAgentAccess",
    "OutboundCallAccess"
  ]
  tags = merge(local.tags, { Name = local.agent_security_profile_name })
}

resource "aws_connect_routing_profile" "primary" {
  instance_id               = aws_connect_instance.this.id
  name                      = local.primary_routing_profile_name
  description               = "Primary routing profile for ${upper(var.region_code)} ${var.environment} agents."
  default_outbound_queue_id = aws_connect_queue.primary.queue_id

  queue_configs {
    channel  = "VOICE"
    delay    = 0
    priority = 1
    queue_id = aws_connect_queue.primary.queue_id
  }

  media_concurrencies {
    channel     = "VOICE"
    concurrency = 1
  }

  tags = merge(local.tags, { Name = local.primary_routing_profile_name })
}

data "aws_connect_security_profile" "admin" {
  count       = var.admin_user_enabled ? 1 : 0
  instance_id = aws_connect_instance.this.id
  name        = "Admin"
}

resource "aws_connect_user" "admin" {
  count              = var.admin_user_enabled ? 1 : 0
  instance_id        = aws_connect_instance.this.id
  name               = var.admin_user_username
  routing_profile_id = aws_connect_routing_profile.primary.routing_profile_id

  security_profile_ids = [
    data.aws_connect_security_profile.admin[0].security_profile_id
  ]

  identity_info {
    first_name      = var.admin_user_first_name
    last_name       = var.admin_user_last_name
    secondary_email = var.admin_user_email
  }

  phone_config {
    after_contact_work_time_limit = 0
    phone_type                    = "SOFT_PHONE"
  }

  tags = local.tags
}

resource "aws_connect_contact_flow" "placeholder" {
  instance_id = aws_connect_instance.this.id
  name        = local.placeholder_flow_name
  type        = "CONTACT_FLOW"
  description = "Placeholder flow for future IVR and routing logic import."
  content = jsonencode({
    Version     = "2019-10-30"
    StartAction = "disconnect"
    Actions = [{
      Identifier  = "disconnect"
      Type        = "DisconnectParticipant"
      Parameters  = {}
      Transitions = {}
    }]
  })
  tags = merge(local.tags, { Name = local.placeholder_flow_name })
}

resource "aws_connect_contact_flow" "transfer_to_agent_customer_queue" {
  count = var.customer_queue_flow_content != null ? 1 : 0

  instance_id = aws_connect_instance.this.id
  name        = local.customer_queue_flow_name
  description = "Customer queue flow for transferring contacts to an available agent."
  type        = "CUSTOMER_QUEUE"
  content     = var.customer_queue_flow_content

  tags = merge(local.tags, {
    Name = local.customer_queue_flow_name
  })
}

resource "aws_connect_contact_flow" "outbound_whisper" {
  count = var.outbound_whisper_flow_content != null ? 1 : 0

  instance_id = aws_connect_instance.this.id
  name        = local.outbound_whisper_flow_name
  description = "Abbvie outbound whisper flow."
  type        = "OUTBOUND_WHISPER"
  content     = var.outbound_whisper_flow_content

  tags = merge(local.tags, {
    Name = local.outbound_whisper_flow_name
  })
}

resource "aws_connect_contact_flow" "agent_to_agent_transfer" {
  count = var.agent_transfer_flow_content != null && var.customer_queue_flow_content != null ? 1 : 0

  instance_id = aws_connect_instance.this.id
  name        = local.agent_transfer_flow_name
  description = "Agent-to-agent transfer flow."
  type        = "AGENT_TRANSFER"
  content = replace(
    var.agent_transfer_flow_content,
    "__CUSTOMER_QUEUE_FLOW_ARN__",
    aws_connect_contact_flow.transfer_to_agent_customer_queue[0].arn
  )

  tags = merge(local.tags, {
    Name = local.agent_transfer_flow_name
  })
}

# Resolve the same BasicQueue used by the source flows within the target instance.
data "aws_connect_queue" "imported_basic" {
  count = (
    try(strcontains(var.hr_flow_content, "__BASIC_QUEUE_ARN__"), false) ||
    anytrue([for flow in values(var.imported_contact_flows) : strcontains(flow.content, "__BASIC_QUEUE_ARN__")])
  ) ? 1 : 0

  instance_id = aws_connect_instance.this.id
  name        = "BasicQueue"
}

resource "aws_connect_contact_flow" "hr" {
  count = var.hr_flow_content != null ? 1 : 0

  instance_id = aws_connect_instance.this.id
  name        = local.hr_flow_name
  description = "Transfers callers to the HR team."
  type        = "CONTACT_FLOW"
  content = replace(
    var.hr_flow_content,
    "__BASIC_QUEUE_ARN__",
    try(data.aws_connect_queue.imported_basic[0].arn, "")
  )

  tags = merge(local.tags, {
    Name = local.hr_flow_name
  })

  lifecycle {
    precondition {
      condition     = var.expected_instance_arn == null ? true : aws_connect_instance.this.arn == var.expected_instance_arn
      error_message = "The managed Connect instance does not match expected_instance_arn. Verify the backend/state before applying."
    }
  }
}

# Imported flows are additional to the existing individual flow resources.
# Agent transfer uses the existing managed transfer customer-queue flow, whose
# Actions and StartAction match the imported transfer customer-queue export.
data "external" "customer_queue_dependencies" {
  for_each = {
    for key, flow in var.imported_contact_flows : key => flow
    if key == "customer_queue"
  }

  program = [var.flow_dependency_python_executable, "${path.module}/scripts/resolve_customer_queue_dependencies.py"]

  query = {
    region         = var.aws_region
    instance_id    = aws_connect_instance.this.id
    instance_arn   = aws_connect_instance.this.arn
    content        = each.value.content
    name_overrides = jsonencode(var.customer_queue_dependency_names)
  }
}

resource "aws_connect_contact_flow" "imported" {
  for_each = {
    for key, flow in var.imported_contact_flows : key => flow
    if key != "main_inbound"
  }

  instance_id = aws_connect_instance.this.id
  name        = each.value.name
  type        = each.value.type
  description = "Imported flow: ${each.value.name}"
  content = replace(
    replace(
      each.key == "customer_queue" ? data.external.customer_queue_dependencies[each.key].result.content : each.value.content,
      "__BASIC_QUEUE_ARN__",
      try(data.aws_connect_queue.imported_basic[0].arn, "")
    ),
    "__CUSTOMER_QUEUE_FLOW_ARN__",
    try(aws_connect_contact_flow.transfer_to_agent_customer_queue[0].arn, "")
  )

  tags = merge(local.tags, {
    Name = each.value.name
  })

  lifecycle {
    precondition {
      condition     = var.expected_instance_arn == null ? true : aws_connect_instance.this.arn == var.expected_instance_arn
      error_message = "The managed Connect instance does not match expected_instance_arn. Verify the backend/state before applying."
    }
    precondition {
      condition     = !strcontains(each.value.content, "__CUSTOMER_QUEUE_FLOW_ARN__") || var.customer_queue_flow_content != null
      error_message = "Flow ${each.value.name} requires the managed transfer customer-queue flow. Supply customer_queue_flow_content."
    }
    precondition {
      condition = (
        can(jsondecode(each.value.content).Actions[0].Type) &&
        can(jsondecode(each.value.content).StartAction)
      )
      error_message = "Flow ${each.value.name} requires a complete JSON export containing StartAction and Actions."
    }
  }
}

# Keep a previously managed main inbound flow when separating its dependencies.
moved {
  from = aws_connect_contact_flow.imported["main_inbound"]
  to   = aws_connect_contact_flow.imported_main_inbound["main_inbound"]
}

# Main inbound depends on the imported customer-queue flow. A separate resource
# avoids referencing another instance of the same for_each resource.
data "aws_connect_queue" "main_inbound" {
  count = contains(keys(var.imported_contact_flows), "main_inbound") ? 1 : 0

  instance_id = aws_connect_instance.this.id
  name = lookup(
    var.customer_queue_dependency_names,
    "BTSGSD-US-MAIN-QUEUE",
    "BTSGSD-US-MAIN-QUEUE"
  )
}

data "aws_connect_contact_flow" "main_inbound_survey" {
  count = (
    contains(keys(var.imported_contact_flows), "main_inbound") &&
    var.lookup_main_inbound_survey
  ) ? 1 : 0

  instance_id = aws_connect_instance.this.id
  name = lookup(
    var.customer_queue_dependency_names,
    "BTSGSD-AIAgent-SurveyFlow",
    "BTSGSD-AIAgent-SurveyFlow"
  )
}

locals {
  main_inbound_survey_arn = (
    var.lookup_main_inbound_survey
    ? try(data.aws_connect_contact_flow.main_inbound_survey[0].arn, null)
    : var.main_inbound_survey_flow_arn
  )
}

resource "aws_connect_contact_flow" "imported_main_inbound" {
  for_each = {
    for key, flow in var.imported_contact_flows : key => flow
    if key == "main_inbound"
  }

  instance_id = aws_connect_instance.this.id
  name        = each.value.name
  type        = each.value.type
  description = "Imported flow: ${each.value.name}"
  content = replace(
    replace(
      replace(
        replace(
          replace(
            each.value.content,
            "__MAIN_CUSTOMER_QUEUE_FLOW_ARN__",
            try(aws_connect_contact_flow.imported["customer_queue"].arn, "")
          ),
          "__CUSTOMER_NUMBER_DATA_TABLE_ID__",
          var.customer_number_data_table_id == null ? "" : var.customer_number_data_table_id
        ),
        "arn:aws:connect:us-east-1:518902362956:instance/0cc3e955-8cdd-4a82-b6fe-7593e1674ffa/queue/23f32241-4ba1-43bb-9b31-5b4fa7e028f4",
        data.aws_connect_queue.main_inbound[0].arn
      ),
      "arn:aws:connect:us-east-1:518902362956:instance/0cc3e955-8cdd-4a82-b6fe-7593e1674ffa/contact-flow/3ac7b9d3-411e-4762-9d86-d74c70b54a94",
      local.main_inbound_survey_arn == null ? "" : local.main_inbound_survey_arn
    ),
    "arn:aws:connect:us-east-1:518902362956:instance/0cc3e955-8cdd-4a82-b6fe-7593e1674ffa/contact-flow/7f068b9c-c1bc-4a43-a26d-a317570a8cd4",
    var.agent_ui_flow_arn == null ? "" : var.agent_ui_flow_arn
  )

  tags = merge(local.tags, {
    Name = each.value.name
  })

  lifecycle {
    precondition {
      condition     = var.expected_instance_arn == null ? true : aws_connect_instance.this.arn == var.expected_instance_arn
      error_message = "The managed Connect instance does not match expected_instance_arn. Verify the backend/state before applying."
    }
    precondition {
      condition = (
        var.lookup_main_inbound_survey ||
        (var.main_inbound_survey_flow_arn == null ? false : startswith(var.main_inbound_survey_flow_arn, "${aws_connect_instance.this.arn}/contact-flow/"))
      )
      error_message = "Supply main_inbound_survey_flow_arn belonging to the target Connect instance when lookup_main_inbound_survey is false."
    }
    precondition {
      condition     = !strcontains(each.value.content, "__MAIN_CUSTOMER_QUEUE_FLOW_ARN__") || contains(keys(var.imported_contact_flows), "customer_queue")
      error_message = "The main inbound flow requires the imported customer_queue flow."
    }
    precondition {
      condition     = !strcontains(each.value.content, "__CUSTOMER_NUMBER_DATA_TABLE_ID__") || var.customer_number_data_table_id != null
      error_message = "The main inbound LangConfig lookup requires customer_number_data_table_id."
    }
    precondition {
      condition = (
        !strcontains(each.value.content, "arn:aws:connect:us-east-1:518902362956:instance/0cc3e955-8cdd-4a82-b6fe-7593e1674ffa/contact-flow/7f068b9c-c1bc-4a43-a26d-a317570a8cd4") ||
        (var.agent_ui_flow_arn == null ? false : startswith(var.agent_ui_flow_arn, "${aws_connect_instance.this.arn}/contact-flow/"))
      )
      error_message = "The main inbound agent UI hook requires agent_ui_flow_arn belonging to the target Connect instance."
    }
    precondition {
      condition = (
        can(jsondecode(each.value.content).Actions[0].Type) &&
        can(jsondecode(each.value.content).StartAction)
      )
      error_message = "Flow ${each.value.name} requires a complete JSON export containing StartAction and Actions."
    }
  }
}
