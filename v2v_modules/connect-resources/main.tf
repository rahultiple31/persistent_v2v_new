locals {
  instance_id  = var.instance_id
  instance_arn = var.instance_arn

  hours_of_operation_name          = "${var.name_prefix}-HoursOfOperation_EN_ES_PT"
  latam_main_queue_name            = "${var.name_prefix}-LATAM-MAIN-QUEUE"
  latam_out_queue_name             = "${var.name_prefix}-LATAM-OUT-QUEUE"
  us_main_queue_name               = "${var.name_prefix}-US-MAIN-QUEUE"
  us_out_queue_name                = "${var.name_prefix}-US-OUT-QUEUE"
  us_vm_queue_name                 = "${var.name_prefix}-US-VM-QUEUE"
  agent_routing_profile_name       = "${var.name_prefix}-US-AGENT-RP"
  latam_agent_routing_profile_name = "${var.name_prefix}-LATAM-AGENT-RP"
  vm_agent_routing_profile_name    = "${var.name_prefix}-VM-AGENT-RP"

  # awscc resources take tags as a list of key/value objects.
  awscc_tags = [for key, value in var.tags : { key = key, value = value }]
}
