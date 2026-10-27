mock_provider "aws" {
  mock_data "aws_connect_instance" {
    defaults = {
      id  = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
      arn = "arn:aws:connect:us-east-1:518902362956:instance/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    }
  }
  mock_resource "aws_connect_contact_flow" {
    defaults = {
      arn             = "arn:aws:connect:us-east-1:518902362956:instance/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/contact-flow/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
      contact_flow_id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    }
  }
}
mock_provider "external" {
  mock_data "external" {
    defaults = { result = { content = "{\"StartAction\":\"test\",\"Actions\":[{\"Type\":\"DisconnectParticipant\"}]}" } }
  }
}

run "flow_names_and_connect_outputs_survive_extraction" {
  command = apply
  module { source = "./tests/fixtures/flow-modules" }
  assert {
    condition = jsonencode(output.flow_names) == jsonencode([
      "BTSGSD-V2V-US-AIAgent-SurveyFlow",
      "BTSGSD-V2V-US-AgentToAgentTransferFlow",
      "BTSGSD-V2V-US-OutboundWhisperFlow",
      "BTSGSD-V2V-US-CustomerQueueFlow",
      "BTSGSD-V2V-US-Views"
    ])
    error_message = "All deployed flow names must survive extraction."
  }
  assert {
    condition = (
      toset(keys(output.imported_ids)) == toset(["agent_transfer", "outbound_whisper", "customer_queue"]) &&
      output.customer_queue_arn == output.extracted_customer_queue_arn
    )
    error_message = "Connect must keep exporting sibling flow IDs and the imported customer queue ARN."
  }
}
