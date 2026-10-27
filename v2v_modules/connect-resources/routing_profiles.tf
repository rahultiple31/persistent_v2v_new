resource "aws_connect_routing_profile" "us_agent" {
  instance_id               = local.instance_id
  name                      = local.agent_routing_profile_name
  description               = local.agent_routing_profile_name
  default_outbound_queue_id = aws_connect_queue.us_out.queue_id

  media_concurrencies {
    channel     = "TASK"
    concurrency = 1
  }

  media_concurrencies {
    channel     = "VOICE"
    concurrency = 1
  }

  tags = merge(var.tags, { Name = local.agent_routing_profile_name })
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

locals {
  routing_profile_ids = {
    basic               = data.aws_connect_routing_profile.basic.routing_profile_id
    us_agent            = aws_connect_routing_profile.us_agent.routing_profile_id
    latam_agent         = aws_connect_routing_profile.latam_agent.routing_profile_id
    us_latam_vm_blended = aws_connect_routing_profile.us_latam_vm_blended.routing_profile_id
  }
}
