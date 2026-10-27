# Custom security profiles.
resource "aws_connect_security_profile" "client_realtime_metrix" {
  instance_id = local.instance_id
  name        = "Client Realtime Metrix"
  description = "Client Realtime Metrix"
  permissions = var.client_realtime_metrix_permissions
  tags        = merge(var.tags, { Name = "Client Realtime Metrix" })
}

resource "aws_connect_security_profile" "supervisor" {
  instance_id = local.instance_id
  name        = "Supervisor"
  description = "BTSGSD_Supervisor"
  permissions = var.supervisor_permissions
  tags        = merge(var.tags, { Name = "Supervisor" })
}

resource "aws_connect_security_profile" "agent_realtime_report_metric" {
  instance_id = local.instance_id
  name        = "Agent Realtime Report Metric"
  description = "Agent Realtime Report Metric"
  permissions = var.agent_realtime_report_metric_permissions
  tags        = merge(var.tags, { Name = "Agent Realtime Report Metric" })
}

resource "aws_connect_security_profile" "agent_lead_access" {
  instance_id = local.instance_id
  name        = "Agent Lead Access"
  description = "Agent Lead Access"
  permissions = var.agent_lead_access_permissions
  tags        = merge(var.tags, { Name = "Agent Lead Access" })
}

resource "aws_connect_security_profile" "limited_access_agent" {
  instance_id = local.instance_id
  name        = "Limited access agent"
  description = "Very limited access granted to an agent"
  permissions = var.limited_access_agent_permissions
  tags        = merge(var.tags, { Name = "Limited access agent" })
}

# Default security profiles created by Connect with every instance.
data "aws_connect_security_profile" "admin" {
  instance_id = local.instance_id
  name        = "Admin"
}

data "aws_connect_security_profile" "agent" {
  instance_id = local.instance_id
  name        = "Agent"
}

data "aws_connect_security_profile" "callcentermanager" {
  instance_id = local.instance_id
  name        = "CallCenterManager"
}

data "aws_connect_security_profile" "qualityanalyst" {
  instance_id = local.instance_id
  name        = "QualityAnalyst"
}

locals {
  security_profile_ids = {
    "Client Realtime Metrix"       = aws_connect_security_profile.client_realtime_metrix.security_profile_id
    "Supervisor"                   = aws_connect_security_profile.supervisor.security_profile_id
    "Agent Realtime Report Metric" = aws_connect_security_profile.agent_realtime_report_metric.security_profile_id
    "Agent Lead Access"            = aws_connect_security_profile.agent_lead_access.security_profile_id
    "Limited access agent"         = aws_connect_security_profile.limited_access_agent.security_profile_id
    "Admin"                        = data.aws_connect_security_profile.admin.security_profile_id
    "Agent"                        = data.aws_connect_security_profile.agent.security_profile_id
    "CallCenterManager"            = data.aws_connect_security_profile.callcentermanager.security_profile_id
    "QualityAnalyst"               = data.aws_connect_security_profile.qualityanalyst.security_profile_id
  }
}
