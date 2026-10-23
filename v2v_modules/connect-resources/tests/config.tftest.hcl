mock_provider "aws" {
  mock_data "aws_connect_user" {
    defaults = {
      user_id = "44444444-4444-4444-4444-444444444444"
    }
  }
  mock_data "aws_connect_security_profile" {
    defaults = {
      security_profile_id = "55555555-5555-5555-5555-555555555555"
    }
  }
  mock_data "aws_connect_routing_profile" {
    defaults = {
      routing_profile_id = "66666666-6666-6666-6666-666666666666"
    }
  }
}

mock_provider "awscc" {}

# Values the root module passes from module.connect / module.connect_queue.
variables {
  instance_id                                    = "11111111-0000-0000-0000-000000000001"
  instance_arn                                   = "arn:aws:connect:us-east-1:111111111111:instance/11111111-0000-0000-0000-000000000001"
  hours_of_operation_id                          = "22222222-0000-0000-0000-000000000002"
  outbound_flow_id                               = "33333333-0000-0000-0000-000000000003"
  quick_connect_flow_id                          = "77777777-0000-0000-0000-000000000007"
  outbound_caller_id_number_id                   = "88888888-0000-0000-0000-000000000008"
  blended_routing_profile_default_outbound_queue = "us_out"
  blended_routing_profile_media_concurrencies    = [{ channel = "VOICE", concurrency = 1 }]
  blended_routing_profile_queues = [
    { queue = "us_vm", channel = "VOICE", priority = 1, delay = 0 },
    { queue = "latam_main", channel = "VOICE", priority = 2, delay = 0 },
  ]
}

run "names_use_v2v_prefix" {
  command = plan

  assert {
    condition = (
      aws_connect_queue.latam_main.name == "BTSGSD-V2V-LATAM-MAIN-QUEUE" &&
      aws_connect_queue.latam_out.name == "BTSGSD-V2V-LATAM-OUT-QUEUE" &&
      aws_connect_queue.us_main.name == "BTSGSD-V2V-US-MAIN-QUEUE" &&
      aws_connect_queue.us_out.name == "BTSGSD-V2V-US-OUT-QUEUE" &&
      aws_connect_queue.us_vm.name == "BTSGSD-V2V-US-VM-QUEUE" &&
      aws_connect_routing_profile.us_agent.name == "BTSGSD-V2V-US-AGENT-RP" &&
      aws_connect_routing_profile.us_latam_vm_blended.name == "BTSGSD-V2V-US-LATAM-VM-BLENDED-RP"
    )
    error_message = "Queue and routing profile names must use the BTSGSD-V2V prefix."
  }
}

run "queues_use_target_instance_inputs" {
  command = apply

  assert {
    condition = alltrue([
      for q in [
        aws_connect_queue.latam_main, aws_connect_queue.latam_out,
        aws_connect_queue.us_main, aws_connect_queue.us_out, aws_connect_queue.us_vm,
      ] :
      q.instance_id == var.instance_id &&
      q.hours_of_operation_id == var.hours_of_operation_id &&
      one(q.outbound_caller_config).outbound_caller_id_number_id == var.outbound_caller_id_number_id &&
      one(q.outbound_caller_config).outbound_flow_id == var.outbound_flow_id
    ])
    error_message = "Queues must use the target instance, connect-queue hours, claimed caller ID and connect outbound flow."
  }
}

run "routing_profiles_reference_module_queues" {
  command = apply

  assert {
    condition = (
      aws_connect_routing_profile.us_agent.default_outbound_queue_id == aws_connect_queue.us_out.queue_id &&
      length(aws_connect_routing_profile.us_agent.media_concurrencies) == 2 &&
      aws_connect_routing_profile.us_latam_vm_blended.default_outbound_queue_id == aws_connect_queue.us_out.queue_id &&
      toset([for qc in aws_connect_routing_profile.us_latam_vm_blended.queue_configs : qc.queue_id]) == toset([aws_connect_queue.us_vm.queue_id, aws_connect_queue.latam_main.queue_id])
    )
    error_message = "Routing profiles must reference the queues created by this module."
  }
}

run "agent_statuses_are_custom_and_enabled" {
  command = apply

  assert {
    condition = (
      length(output.agent_status_arns) == 15 &&
      awscc_connect_agent_status.lunch.instance_arn == var.instance_arn &&
      awscc_connect_agent_status.lunch.type == "CUSTOM" &&
      awscc_connect_agent_status.lunch.state == "ENABLED"
    )
    error_message = "All fifteen custom agent statuses must be enabled on the target instance."
  }
}

run "users_and_quick_connects_created_by_default" {
  command = apply

  assert {
    condition = (
      length(aws_connect_user.this) == 13 &&
      aws_connect_user.this["smita.kulkarni@abbvie.com"].routing_profile_id == aws_connect_routing_profile.us_latam_vm_blended.routing_profile_id &&
      aws_connect_user.this["bharat.patchigolla@abbvie.com"].routing_profile_id == "66666666-6666-6666-6666-666666666666" &&
      one(aws_connect_quick_connect.smita_kulkarni.quick_connect_config[0].user_config).user_id == aws_connect_user.this["smita.kulkarni@abbvie.com"].user_id &&
      one(aws_connect_quick_connect.smita_kulkarni.quick_connect_config[0].user_config).contact_flow_id == var.quick_connect_flow_id
    )
    error_message = "Users must be created with their routing profiles and quick connects must reference them and the connect transfer flow."
  }
}

run "moh_prompt_skipped_without_s3_uri" {
  command = plan

  assert {
    condition     = length(awscc_connect_prompt.moh_30sec) == 0
    error_message = "MOH_30SEC must not be created until its S3 URI is supplied."
  }
}

run "moh_prompt_created_with_s3_uri" {
  command = plan
  variables {
    moh_30sec_prompt_s3_uri = "s3://example-bucket/prompts/MOH_30SEC.wav"
  }

  assert {
    condition     = length(awscc_connect_prompt.moh_30sec) == 1 && awscc_connect_prompt.moh_30sec[0].instance_arn == var.instance_arn
    error_message = "MOH_30SEC must be created on the target instance once its S3 URI is supplied."
  }
}

run "reject_phone_number_as_caller_id" {
  command = plan
  variables {
    outbound_caller_id_number_id = "+18557113853"
  }
  expect_failures = [var.outbound_caller_id_number_id]
}

run "reject_unknown_queue_key" {
  command = plan
  variables {
    blended_routing_profile_default_outbound_queue = "BTSGSD-V2V-US-OUT-QUEUE"
  }
  expect_failures = [var.blended_routing_profile_default_outbound_queue]
}
