# Custom agent statuses. Available and Offline are system-managed by Connect.
# hashicorp/aws has no agent status resource, so these use the awscc provider.
resource "awscc_connect_agent_status" "after_call_work" {
  instance_arn = local.instance_arn
  name         = "After Call Work"
  description  = "After Call Work State"
  state        = "ENABLED"
  type         = "CUSTOM"
  tags         = local.awscc_tags
}

resource "awscc_connect_agent_status" "backlog" {
  instance_arn = local.instance_arn
  name         = "Backlog"
  description  = "Backlog state"
  state        = "ENABLED"
  type         = "CUSTOM"
  tags         = local.awscc_tags
}

resource "awscc_connect_agent_status" "bio_break" {
  instance_arn = local.instance_arn
  name         = "Bio Break"
  description  = "Bio Break State"
  state        = "ENABLED"
  type         = "CUSTOM"
  tags         = local.awscc_tags
}

resource "awscc_connect_agent_status" "break" {
  instance_arn = local.instance_arn
  name         = "Break"
  description  = "Break state"
  state        = "ENABLED"
  type         = "CUSTOM"
  tags         = local.awscc_tags
}

resource "awscc_connect_agent_status" "call_outbound" {
  instance_arn = local.instance_arn
  name         = "Call Outbound"
  description  = "Call Outbound state"
  state        = "ENABLED"
  type         = "CUSTOM"
  tags         = local.awscc_tags
}

resource "awscc_connect_agent_status" "chat" {
  instance_arn = local.instance_arn
  name         = "Chat"
  description  = "Chat state"
  state        = "ENABLED"
  type         = "CUSTOM"
  tags         = local.awscc_tags
}

resource "awscc_connect_agent_status" "consultation" {
  instance_arn = local.instance_arn
  name         = "Consultation"
  description  = "Consultation state"
  state        = "ENABLED"
  type         = "CUSTOM"
  tags         = local.awscc_tags
}

resource "awscc_connect_agent_status" "email" {
  instance_arn = local.instance_arn
  name         = "Email"
  description  = "Email state"
  state        = "ENABLED"
  type         = "CUSTOM"
  tags         = local.awscc_tags
}

resource "awscc_connect_agent_status" "escalations" {
  instance_arn = local.instance_arn
  name         = "Escalations"
  description  = "Escalations state"
  state        = "ENABLED"
  type         = "CUSTOM"
  tags         = local.awscc_tags
}

resource "awscc_connect_agent_status" "external_vms" {
  instance_arn = local.instance_arn
  name         = "External VMs"
  description  = "External VMs state"
  state        = "ENABLED"
  type         = "CUSTOM"
  tags         = local.awscc_tags
}

resource "awscc_connect_agent_status" "follow_ups" {
  instance_arn = local.instance_arn
  name         = "Follow-ups"
  description  = "Follow-ups state"
  state        = "ENABLED"
  type         = "CUSTOM"
  tags         = local.awscc_tags
}

resource "awscc_connect_agent_status" "internal_vms" {
  instance_arn = local.instance_arn
  name         = "Internal VMs"
  description  = "Internal VMs State"
  state        = "ENABLED"
  type         = "CUSTOM"
  tags         = local.awscc_tags
}

resource "awscc_connect_agent_status" "lunch" {
  instance_arn = local.instance_arn
  name         = "Lunch"
  description  = "Lunch Break"
  state        = "ENABLED"
  type         = "CUSTOM"
  tags         = local.awscc_tags
}

resource "awscc_connect_agent_status" "remote_session" {
  instance_arn = local.instance_arn
  name         = "RemoteSession"
  description  = "RemoteSession state"
  state        = "ENABLED"
  type         = "CUSTOM"
  tags         = local.awscc_tags
}

resource "awscc_connect_agent_status" "training" {
  instance_arn = local.instance_arn
  name         = "Training"
  description  = "Training state"
  state        = "ENABLED"
  type         = "CUSTOM"
  tags         = local.awscc_tags
}
