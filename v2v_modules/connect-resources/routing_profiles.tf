# US agent routing profile. Managed with awscc because hashicorp/aws has no
# support for manual-assignment queues. Matches source BTSGSD-DEV-SSO-US-AGENT-RP:
# no standard queues, US-MAIN as a VOICE manual-assignment queue.
resource "awscc_connect_routing_profile" "us_agent" {
  instance_arn               = local.instance_arn
  name                       = local.agent_routing_profile_name
  description                = local.agent_routing_profile_name
  default_outbound_queue_arn = aws_connect_queue.us_out.arn
  agent_availability_timer   = "TIME_SINCE_LAST_ACTIVITY"

  media_concurrencies = [
    {
      channel                = "TASK"
      concurrency            = 1
      cross_channel_behavior = { behavior_type = "ROUTE_CURRENT_CHANNEL_ONLY" }
    },
    {
      channel                = "VOICE"
      concurrency            = 1
      cross_channel_behavior = { behavior_type = "ROUTE_CURRENT_CHANNEL_ONLY" }
    },
  ]

  manual_assignment_queue_configs = [
    {
      queue_reference = {
        channel   = "VOICE"
        queue_arn = aws_connect_queue.us_main.arn
      }
    },
  ]

  tags = [for key, value in merge(var.tags, { Name = local.agent_routing_profile_name }) : { key = key, value = value }]
}

# The profile was previously managed as aws_connect_routing_profile.us_agent.
# Drop that address from state without deleting the profile; the root module
# imports the same profile into awscc_connect_routing_profile.us_agent.
removed {
  from = aws_connect_routing_profile.us_agent

  lifecycle {
    destroy = false
  }
}

resource "aws_connect_routing_profile" "us_latam_vm_blended" {
  instance_id               = local.instance_id
  name                      = local.latam_vm_blended_routing_profile
  description               = local.latam_vm_blended_routing_profile
  default_outbound_queue_id = aws_connect_queue.us_out.queue_id

  media_concurrencies {
    channel     = "TASK"
    concurrency = 1
  }

  media_concurrencies {
    channel     = "VOICE"
    concurrency = 1
  }

  queue_configs {
    channel  = "TASK"
    delay    = 0
    priority = 1
    queue_id = aws_connect_queue.us_vm.queue_id
  }

  queue_configs {
    channel  = "VOICE"
    delay    = 0
    priority = 1
    queue_id = aws_connect_queue.us_vm.queue_id
  }

  # Main queue managed by the connect-queue module.
  queue_configs {
    channel  = "VOICE"
    delay    = 0
    priority = 1
    queue_id = var.connect_queue_queue_id
  }

  queue_configs {
    channel  = "VOICE"
    delay    = 0
    priority = 1
    queue_id = aws_connect_queue.latam_main.queue_id
  }

  tags = merge(var.tags, { Name = local.latam_vm_blended_routing_profile })
}

resource "aws_connect_routing_profile" "latam_agent" {
  instance_id               = local.instance_id
  name                      = local.latam_agent_routing_profile_name
  description               = local.latam_agent_routing_profile_name
  default_outbound_queue_id = aws_connect_queue.latam_out.queue_id

  media_concurrencies {
    channel     = "TASK"
    concurrency = 1
  }

  media_concurrencies {
    channel     = "VOICE"
    concurrency = 1
  }

  queue_configs {
    channel  = "VOICE"
    delay    = 0
    priority = 1
    queue_id = aws_connect_queue.latam_main.queue_id
  }

  tags = merge(var.tags, { Name = local.latam_agent_routing_profile_name })
}

# Default routing profile created by Connect with every instance.
data "aws_connect_routing_profile" "basic" {
  instance_id = local.instance_id
  name        = "Basic Routing Profile"
}

# Users can't reference awscc_connect_routing_profile.us_agent directly: it
# routes US-MAIN, US-MAIN carries the user quick connects, and those depend on
# the users (a dependency cycle). Users on us_agent look the profile up by name
# instead; the lookup only exists when a user is assigned to it.
data "aws_connect_routing_profile" "us_agent_lookup" {
  count = var.create_users && contains([for user in values(var.users) : user.routing_profile], "us_agent") ? 1 : 0

  instance_id = local.instance_id
  name        = local.agent_routing_profile_name
}

locals {
  # Output map: IDs of the routing profiles this module manages or uses.
  routing_profile_ids = {
    basic = data.aws_connect_routing_profile.basic.routing_profile_id
    # awscc exposes the ARN only: .../instance/<instance-id>/routing-profile/<id>
    us_agent            = element(split("/", awscc_connect_routing_profile.us_agent.routing_profile_arn), 3)
    latam_agent         = aws_connect_routing_profile.latam_agent.routing_profile_id
    us_latam_vm_blended = aws_connect_routing_profile.us_latam_vm_blended.routing_profile_id
  }

  # Map used by aws_connect_user; avoids the us_agent cycle described above.
  user_routing_profile_ids = {
    basic               = data.aws_connect_routing_profile.basic.routing_profile_id
    us_agent            = try(data.aws_connect_routing_profile.us_agent_lookup[0].routing_profile_id, null)
    latam_agent         = aws_connect_routing_profile.latam_agent.routing_profile_id
    us_latam_vm_blended = aws_connect_routing_profile.us_latam_vm_blended.routing_profile_id
  }
}
