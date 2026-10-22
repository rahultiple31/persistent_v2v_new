data "aws_connect_instance" "existing" {
  instance_alias = var.instance_alias
}

data "aws_connect_contact_flow" "outbound" {
  count = var.outbound_phone_number_id != null ? 1 : 0

  instance_id = data.aws_connect_instance.existing.id
  name        = var.outbound_flow_name
}

locals {
  instance_id = data.aws_connect_instance.existing.id
  days = toset([
    "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY",
    "FRIDAY", "SATURDAY", "SUNDAY"
  ])
  quick_connect_names = toset(["BTSGSD-V2V-US-FF Help Desk", "BTSGSD-V2V-US-HR Help Desk"])
}

resource "aws_connect_hours_of_operation" "hours" {
  instance_id = local.instance_id
  name        = "BTSGSD-V2V-US-HoursOfOperation_EN_ES_PT"
  description = "Open 24 hours daily."
  time_zone   = "America/New_York"

  dynamic "config" {
    for_each = local.days
    content {
      day = config.value
      start_time {
        hours   = 0
        minutes = 0
      }
      end_time {
        hours   = 0
        minutes = 0
      }
    }
  }

  tags = var.tags
}

resource "aws_connect_quick_connect" "help_desk" {
  for_each = local.quick_connect_names

  instance_id = local.instance_id
  name        = each.value
  quick_connect_config {
    quick_connect_type = "PHONE_NUMBER"
    phone_config {
      phone_number = "+18557113853"
    }
  }
  tags = var.tags
}

resource "aws_connect_queue" "queue" {
  instance_id           = local.instance_id
  name                  = var.queue_name
  hours_of_operation_id = aws_connect_hours_of_operation.hours.hours_of_operation_id
  status                = "ENABLED"

  dynamic "outbound_caller_config" {
    for_each = var.outbound_phone_number_id == null ? [] : [var.outbound_phone_number_id]

    content {
      outbound_caller_id_number_id = outbound_caller_config.value
      outbound_flow_id             = data.aws_connect_contact_flow.outbound[0].contact_flow_id
    }
  }

  quick_connect_ids = [for qc in aws_connect_quick_connect.help_desk : qc.quick_connect_id]
  tags              = var.tags

  lifecycle {
    precondition {
      condition     = var.outbound_phone_number_id == null || can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.outbound_phone_number_id))
      error_message = "Set outbound_phone_number_id to a phone-number UUID claimed by the selected Connect instance, or leave it null to omit outbound caller configuration."
    }
  }
}
