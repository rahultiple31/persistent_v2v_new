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

# Flows the root module passes in by ID, as the connect module creates them.
override_data {
  target = data.aws_connect_contact_flow.outbound_whisper
  values = {
    contact_flow_id = "33333333-0000-0000-0000-000000000003"
    name            = "BTSGSD-V2V-US-outbound-whisper-flow"
  }
}

override_data {
  target = data.aws_connect_contact_flow.quick_connect
  values = {
    contact_flow_id = "77777777-0000-0000-0000-000000000007"
    name            = "BTSGSD-V2V-AgentToAgentTransferFlow"
  }
}

# Values the root module passes from module.connect / module.connect_queue.
variables {
  instance_id                  = "11111111-0000-0000-0000-000000000001"
  instance_arn                 = "arn:aws:connect:us-east-1:111111111111:instance/11111111-0000-0000-0000-000000000001"
  outbound_flow_id             = "33333333-0000-0000-0000-000000000003"
  quick_connect_flow_id        = "77777777-0000-0000-0000-000000000007"
  outbound_caller_id_number_id = "88888888-0000-0000-0000-000000000008"
  connect_queue_queue_id       = "99999999-0000-0000-0000-000000000009"
  help_desk_quick_connect_ids  = ["aaaaaaaa-0000-0000-0000-00000000000a", "bbbbbbbb-0000-0000-0000-00000000000b"]
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
      aws_connect_routing_profile.latam_agent.name == "BTSGSD-V2V-LATAM-AGENT-RP" &&
      aws_connect_routing_profile.us_latam_vm_blended.name == "BTSGSD-V2V-US-LATAM-VM-BLENDED-RP" &&
      aws_connect_hours_of_operation.v2v.name == "BTSGSD-V2V-HoursOfOperation_EN_ES_PT"
    )
    error_message = "Queue, routing profile and hours of operation names must use the BTSGSD-V2V prefix."
  }
}

run "queues_use_v2v_hours_and_outbound_whisper_flow" {
  command = apply

  assert {
    condition = alltrue([
      for q in [
        aws_connect_queue.latam_main, aws_connect_queue.latam_out,
        aws_connect_queue.us_main, aws_connect_queue.us_out, aws_connect_queue.us_vm,
      ] :
      q.instance_id == var.instance_id &&
      q.hours_of_operation_id == aws_connect_hours_of_operation.v2v.hours_of_operation_id &&
      one(q.outbound_caller_config).outbound_caller_id_number_id == var.outbound_caller_id_number_id &&
      one(q.outbound_caller_config).outbound_flow_id == var.outbound_flow_id
    ])
    error_message = "Queues must use the V2V hours of operation, the claimed caller ID and the V2V outbound whisper flow."
  }

  assert {
    condition = (
      length(aws_connect_hours_of_operation.v2v.config) == 7 &&
      aws_connect_hours_of_operation.v2v.time_zone == "America/New_York" &&
      alltrue([for day in aws_connect_hours_of_operation.v2v.config :
        one(day.start_time).hours == 0 && one(day.start_time).minutes == 0 &&
        one(day.end_time).hours == 0 && one(day.end_time).minutes == 0
      ])
    )
    error_message = "V2V hours of operation must be open 24 hours every day in America/New_York."
  }
}

run "main_queues_have_quick_connects" {
  command = apply

  assert {
    condition = (
      aws_connect_queue.us_main.quick_connect_ids == toset(concat(
        [
          aws_connect_quick_connect.mahendra_kumar.quick_connect_id,
          aws_connect_quick_connect.smita_kulkarni.quick_connect_id,
          aws_connect_quick_connect.govind_khandelwal.quick_connect_id,
        ],
        var.help_desk_quick_connect_ids,
      )) &&
      aws_connect_queue.latam_main.quick_connect_ids == toset(var.help_desk_quick_connect_ids)
    )
    error_message = "US-MAIN must have the user and help-desk quick connects; LATAM-MAIN must have the help-desk quick connects."
  }
}

run "routing_profiles_reference_module_queues" {
  command = apply

  assert {
    condition = (
      aws_connect_routing_profile.us_agent.default_outbound_queue_id == aws_connect_queue.us_out.queue_id &&
      length(aws_connect_routing_profile.us_agent.media_concurrencies) == 2 &&
      aws_connect_routing_profile.latam_agent.default_outbound_queue_id == aws_connect_queue.latam_out.queue_id &&
      length(aws_connect_routing_profile.latam_agent.media_concurrencies) == 2 &&
      [for qc in aws_connect_routing_profile.latam_agent.queue_configs : [qc.queue_id, qc.channel, qc.priority, qc.delay]] == [[aws_connect_queue.latam_main.queue_id, "VOICE", 1, 0]] &&
      aws_connect_routing_profile.us_latam_vm_blended.default_outbound_queue_id == aws_connect_queue.us_out.queue_id &&
      length(aws_connect_routing_profile.us_latam_vm_blended.media_concurrencies) == 2 &&
      length(aws_connect_routing_profile.us_latam_vm_blended.queue_configs) == 4 &&
      toset([for qc in aws_connect_routing_profile.us_latam_vm_blended.queue_configs : qc.queue_id]) == toset([
        aws_connect_queue.us_vm.queue_id, aws_connect_queue.latam_main.queue_id, var.connect_queue_queue_id,
      ])
    )
    error_message = "Routing profiles must match the source configuration and reference the module and connect-queue queues."
  }
}

run "security_profiles_have_source_descriptions" {
  command = plan

  assert {
    condition = (
      aws_connect_security_profile.client_realtime_metrix.description == "Client Realtime Metrix" &&
      aws_connect_security_profile.supervisor.description == "BTSGSD_Supervisor" &&
      aws_connect_security_profile.agent_realtime_report_metric.description == "Agent Realtime Report Metric" &&
      aws_connect_security_profile.agent_lead_access.description == "Agent Lead Access" &&
      aws_connect_security_profile.limited_access_agent.description == "Very limited access granted to an agent"
    )
    error_message = "Custom security profiles must carry the source instance descriptions."
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

run "reject_default_outbound_flow" {
  command = plan

  override_data {
    target = data.aws_connect_contact_flow.outbound_whisper
    values = {
      contact_flow_id = "33333333-0000-0000-0000-000000000003"
      name            = "Default outbound"
    }
  }

  expect_failures = [data.aws_connect_contact_flow.outbound_whisper]
}

run "reject_default_agent_transfer_flow" {
  command = plan

  override_data {
    target = data.aws_connect_contact_flow.quick_connect
    values = {
      contact_flow_id = "77777777-0000-0000-0000-000000000007"
      name            = "Default agent transfer"
    }
  }

  expect_failures = [data.aws_connect_contact_flow.quick_connect]
}
