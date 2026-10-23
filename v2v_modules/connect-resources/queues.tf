resource "aws_connect_queue" "latam_main" {
  instance_id           = local.instance_id
  name                  = local.latam_main_queue_name
  description           = local.latam_main_queue_name
  hours_of_operation_id = var.hours_of_operation_id
  status                = "ENABLED"

  outbound_caller_config {
    outbound_caller_id_number_id = var.outbound_caller_id_number_id
    outbound_flow_id             = var.outbound_flow_id
  }

  tags = merge(var.tags, { Name = local.latam_main_queue_name })
}

resource "aws_connect_queue" "latam_out" {
  instance_id           = local.instance_id
  name                  = local.latam_out_queue_name
  description           = local.latam_out_queue_name
  hours_of_operation_id = var.hours_of_operation_id
  status                = "ENABLED"

  outbound_caller_config {
    outbound_caller_id_number_id = var.outbound_caller_id_number_id
    outbound_flow_id             = var.outbound_flow_id
  }

  tags = merge(var.tags, { Name = local.latam_out_queue_name })
}

resource "aws_connect_queue" "us_main" {
  instance_id           = local.instance_id
  name                  = local.us_main_queue_name
  description           = local.us_main_queue_name
  hours_of_operation_id = var.hours_of_operation_id
  status                = "ENABLED"

  outbound_caller_config {
    outbound_caller_id_number_id = var.outbound_caller_id_number_id
    outbound_flow_id             = var.outbound_flow_id
  }

  tags = merge(var.tags, { Name = local.us_main_queue_name })
}

resource "aws_connect_queue" "us_out" {
  instance_id           = local.instance_id
  name                  = local.us_out_queue_name
  description           = local.us_out_queue_name
  hours_of_operation_id = var.hours_of_operation_id
  status                = "ENABLED"

  outbound_caller_config {
    outbound_caller_id_number_id = var.outbound_caller_id_number_id
    outbound_flow_id             = var.outbound_flow_id
  }

  tags = merge(var.tags, { Name = local.us_out_queue_name })
}

resource "aws_connect_queue" "us_vm" {
  instance_id           = local.instance_id
  name                  = local.us_vm_queue_name
  description           = local.us_vm_queue_name
  hours_of_operation_id = var.hours_of_operation_id
  status                = "ENABLED"

  outbound_caller_config {
    outbound_caller_id_number_id = var.outbound_caller_id_number_id
    outbound_flow_id             = var.outbound_flow_id
  }

  tags = merge(var.tags, { Name = local.us_vm_queue_name })
}

locals {
  queue_ids = {
    latam_main = aws_connect_queue.latam_main.queue_id
    latam_out  = aws_connect_queue.latam_out.queue_id
    us_main    = aws_connect_queue.us_main.queue_id
    us_out     = aws_connect_queue.us_out.queue_id
    us_vm      = aws_connect_queue.us_vm.queue_id
  }
}
