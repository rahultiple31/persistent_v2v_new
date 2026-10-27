# Outbound whisper flow passed in by ID. The postcondition stops the queues
# from being created or updated if "Default outbound" is wired in from the
# root module.
data "aws_connect_contact_flow" "outbound_whisper" {
  instance_id     = local.instance_id
  contact_flow_id = var.outbound_flow_id

  lifecycle {
    postcondition {
      condition     = self.name != "Default outbound"
      error_message = "outbound_flow_id must be the V2V outbound whisper flow (module.connect.outbound_whisper_flow_id), not \"Default outbound\"."
    }
  }
}

locals {
  outbound_flow_id = data.aws_connect_contact_flow.outbound_whisper.contact_flow_id

  # Quick connects attached to US-MAIN in the source instance: the three user
  # quick connects plus the connect-queue help-desk quick connects.
  us_main_quick_connect_ids = concat(
    [
      aws_connect_quick_connect.mahendra_kumar.quick_connect_id,
      aws_connect_quick_connect.smita_kulkarni.quick_connect_id,
      aws_connect_quick_connect.govind_khandelwal.quick_connect_id,
    ],
    var.help_desk_quick_connect_ids,
  )
}

resource "aws_connect_queue" "latam_main" {
  instance_id           = local.instance_id
  name                  = local.latam_main_queue_name
  description           = local.latam_main_queue_name
  hours_of_operation_id = aws_connect_hours_of_operation.v2v.hours_of_operation_id
  status                = "ENABLED"

  # Only the help-desk quick connects. The user quick connects (Mahendra,
  # Smita, Govind) would create a dependency cycle: those users are on the
  # blended and LATAM agent routing profiles, which route this queue.
  quick_connect_ids = var.help_desk_quick_connect_ids

  outbound_caller_config {
    outbound_caller_id_number_id = var.outbound_caller_id_number_id
    outbound_flow_id             = local.outbound_flow_id
  }

  tags = merge(var.tags, { Name = local.latam_main_queue_name })
}

resource "aws_connect_queue" "latam_out" {
  instance_id           = local.instance_id
  name                  = local.latam_out_queue_name
  description           = local.latam_out_queue_name
  hours_of_operation_id = aws_connect_hours_of_operation.v2v.hours_of_operation_id
  status                = "ENABLED"

  outbound_caller_config {
    outbound_caller_id_number_id = var.outbound_caller_id_number_id
    outbound_flow_id             = local.outbound_flow_id
  }

  tags = merge(var.tags, { Name = local.latam_out_queue_name })
}

resource "aws_connect_queue" "us_main" {
  instance_id           = local.instance_id
  name                  = local.us_main_queue_name
  description           = local.us_main_queue_name
  hours_of_operation_id = aws_connect_hours_of_operation.v2v.hours_of_operation_id
  status                = "ENABLED"
  quick_connect_ids     = local.us_main_quick_connect_ids

  outbound_caller_config {
    outbound_caller_id_number_id = var.outbound_caller_id_number_id
    outbound_flow_id             = local.outbound_flow_id
  }

  tags = merge(var.tags, { Name = local.us_main_queue_name })
}

resource "aws_connect_queue" "us_out" {
  instance_id           = local.instance_id
  name                  = local.us_out_queue_name
  description           = local.us_out_queue_name
  hours_of_operation_id = aws_connect_hours_of_operation.v2v.hours_of_operation_id
  status                = "ENABLED"

  outbound_caller_config {
    outbound_caller_id_number_id = var.outbound_caller_id_number_id
    outbound_flow_id             = local.outbound_flow_id
  }

  tags = merge(var.tags, { Name = local.us_out_queue_name })
}

resource "aws_connect_queue" "us_vm" {
  instance_id           = local.instance_id
  name                  = local.us_vm_queue_name
  description           = local.us_vm_queue_name
  hours_of_operation_id = aws_connect_hours_of_operation.v2v.hours_of_operation_id
  status                = "ENABLED"

  outbound_caller_config {
    outbound_caller_id_number_id = var.outbound_caller_id_number_id
    outbound_flow_id             = local.outbound_flow_id
  }

  tags = merge(var.tags, { Name = local.us_vm_queue_name })
}
