mock_provider "aws" {
  mock_data "aws_connect_instance" {
    defaults = {
      id  = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
      arn = "arn:aws:connect:us-east-1:518902362956:instance/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    }
  }
  mock_data "aws_connect_contact_flow" {
    defaults = {
      contact_flow_id = "11111111-1111-1111-1111-111111111111"
    }
  }
}

variables {
  instance_alias           = "btsgsd-dev-v2v-poc-us-east-1"
  queue_name               = "BTSGSD-V2V-US-DEV SSO-US-MAIN-QUEUE"
  outbound_phone_number_id = "22222222-2222-2222-2222-222222222222"
}

run "hours_quick_connects_and_outbound_configuration" {
  command = apply

  assert {
    condition = (
      aws_connect_hours_of_operation.hours.time_zone == "America/New_York" &&
      length(aws_connect_hours_of_operation.hours.config) == 7 &&
      alltrue([for day in aws_connect_hours_of_operation.hours.config :
        one(day.start_time).hours == 0 && one(day.start_time).minutes == 0 &&
        one(day.end_time).hours == 0 && one(day.end_time).minutes == 0
      ]) &&
      aws_connect_hours_of_operation.hours.tags["Env"] == "Dev" &&
      aws_connect_hours_of_operation.hours.tags["Org"] == "btsgsd"
    )
    error_message = "Hours must cover every day from midnight to midnight in America/New_York with the requested tags."
  }

  assert {
    condition = (
      toset(keys(aws_connect_quick_connect.help_desk)) == toset(["BTSGSD-V2V-US-FF Help Desk", "BTSGSD-V2V-US-HR Help Desk"]) &&
      alltrue([for qc in aws_connect_quick_connect.help_desk :
        one(qc.quick_connect_config).quick_connect_type == "PHONE_NUMBER" &&
        one(one(qc.quick_connect_config).phone_config).phone_number == "+18557113853"
      ]) &&
      toset(aws_connect_queue.queue.quick_connect_ids) == toset(values(output.quick_connect_ids))
    )
    error_message = "Both phone quick connects must be attached to the queue and dial +18557113853."
  }

  assert {
    condition = (
      aws_connect_queue.queue.instance_id == "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" &&
      aws_connect_queue.queue.hours_of_operation_id == output.hours_of_operation_id &&
      one(aws_connect_queue.queue.outbound_caller_config).outbound_caller_id_number_id == var.outbound_phone_number_id &&
      one(aws_connect_queue.queue.outbound_caller_config).outbound_flow_id == "11111111-1111-1111-1111-111111111111" &&
      data.aws_connect_contact_flow.outbound[0].name == "Default outbound"
    )
    error_message = "The queue must use the existing instance, claimed phone-number ID, managed hours and Default outbound flow."
  }
}

run "reject_placeholder_phone_id" {
  command = plan
  variables { outbound_phone_number_id = "REPLACE_WITH_CLAIMED_PHONE_NUMBER_ID" }
  expect_failures = [aws_connect_queue.queue]
}

run "unset_phone_does_not_reuse_dev_outbound_configuration" {
  command = plan

  variables {
    outbound_phone_number_id = null
  }

  assert {
    condition = (
      length(aws_connect_queue.queue.outbound_caller_config) == 0 &&
      length(data.aws_connect_contact_flow.outbound) == 0
    )
    error_message = "Without a POC phone-number ID, omit outbound caller configuration and its flow lookup."
  }
}

run "reject_phone_number_as_resource_id" {
  command = plan
  variables { outbound_phone_number_id = "+18557113853" }
  expect_failures = [aws_connect_queue.queue]
}
