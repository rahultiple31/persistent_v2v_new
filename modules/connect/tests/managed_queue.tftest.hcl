mock_provider "aws" {
  mock_resource "aws_connect_instance" {
    defaults = {
      id  = "c227a737-3e4f-4c64-8397-2d37e318801d"
      arn = "arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d"
    }
  }
}
mock_provider "external" {}

variables {
  project_name         = "btsgsd"
  environment          = "dev"
  aws_region           = "us-east-1"
  region_code          = "us-east-1"
  common_tags          = {}
  contact_center_alias = "btsgsd"

  lookup_main_inbound_queue = false
  main_inbound_queue_arn    = "arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d/queue/33333333-3333-3333-3333-333333333333"

  imported_contact_flows = {
    main_inbound = {
      name = "btsgsd-Main-IB-Flow"
      type = "CONTACT_FLOW"
      content = jsonencode({
        Version = "2019-10-30", StartAction = "Escalate"
        Actions = [
          {
            Identifier = "Escalate", Type = "UpdateContactTargetQueue"
            Parameters = { QueueId = "arn:aws:connect:us-east-1:518902362956:instance/0cc3e955-8cdd-4a82-b6fe-7593e1674ffa/queue/23f32241-4ba1-43bb-9b31-5b4fa7e028f4" }
            Transitions = {
              NextAction = "done"
              Errors     = [{ NextAction = "done", ErrorType = "NoMatchingError" }]
            }
          },
          { Identifier = "done", Type = "DisconnectParticipant", Parameters = {}, Transitions = {} }
        ]
      })
    }
  }
}

run "managed_queue_skips_lookup_and_renders_inbound" {
  command = apply
  assert {
    condition = (
      length(data.aws_connect_queue.main_inbound) == 0 &&
      jsondecode(aws_connect_contact_flow.imported_main_inbound["main_inbound"].content).Actions[0].Parameters.QueueId == var.main_inbound_queue_arn
    )
    error_message = "Inbound routing must use the newly created queue directly without a name lookup."
  }
}

run "reject_queue_from_source_instance" {
  command = plan
  variables {
    main_inbound_queue_arn = "arn:aws:connect:us-east-1:518902362956:instance/0cc3e955-8cdd-4a82-b6fe-7593e1674ffa/queue/23f32241-4ba1-43bb-9b31-5b4fa7e028f4"
  }
  expect_failures = [aws_connect_contact_flow.imported_main_inbound["main_inbound"]]
}

run "managed_queue_requires_arn" {
  command = plan
  variables { main_inbound_queue_arn = null }
  expect_failures = [aws_connect_contact_flow.imported_main_inbound["main_inbound"]]
}
