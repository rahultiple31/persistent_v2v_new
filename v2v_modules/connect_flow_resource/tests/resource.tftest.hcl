mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { region = "us-east-1" }
  }
}

mock_provider "external" {
  mock_data "external" {
    defaults = { result = { content = "{\"StartAction\":\"resolved\",\"Actions\":[{\"Type\":\"DisconnectParticipant\"}]}" } }
  }
}

variables {
  flow = {
    name                  = "BTSGSD-V2V-US-test-flow"
    type                  = "CONTACT_FLOW"
    description           = "Preserved description"
    instance_arn          = "arn:aws:connect:us-east-1:518902362956:instance/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    expected_instance_arn = "arn:aws:connect:us-east-1:518902362956:instance/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    tags                  = { Service = "original", Name = "old" }
    content               = "{\"StartAction\":\"original\",\"Actions\":[{\"Type\":\"DisconnectParticipant\"}]}"
  }
}

run "preserve_raw_flow_without_dependency_lookup" {
  command = plan

  assert {
    condition = (
      aws_connect_contact_flow.this.content == var.flow.content &&
      aws_connect_contact_flow.this.instance_id == "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" &&
      aws_connect_contact_flow.this.name == var.flow.name &&
      aws_connect_contact_flow.this.description == var.flow.description &&
      aws_connect_contact_flow.this.type == var.flow.type &&
      aws_connect_contact_flow.this.tags == tomap({ Service = "original", Name = var.flow.name }) &&
      length(data.external.dependencies) == 0
    )
    error_message = "Flow metadata, tags and content must remain intact without executing the resolver."
  }
}

run "use_resolver_content_and_target_context" {
  command = plan
  variables {
    flow = {
      name                 = "BTSGSD-V2V-US-test-flow"
      type                 = "CUSTOMER_QUEUE"
      description          = "Imported flow"
      instance_arn         = "arn:aws:connect:us-east-1:518902362956:instance/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
      resolve_dependencies = true
      python_executable    = "python3"
      dependency_names     = { exported = "target" }
      content              = "{\"StartAction\":\"original\",\"Actions\":[{\"Type\":\"DisconnectParticipant\"}]}"
    }
  }
  assert {
    condition = (
      jsondecode(aws_connect_contact_flow.this.content).StartAction == "resolved" &&
      data.external.dependencies[0].query.region == "us-east-1" &&
      data.external.dependencies[0].query.instance_id == "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" &&
      data.external.dependencies[0].query.instance_arn == var.flow.instance_arn &&
      data.external.dependencies[0].query.content == var.flow.content &&
      jsondecode(data.external.dependencies[0].query.name_overrides).exported == "target"
    )
    error_message = "Resolve the original rendered content against the same target instance and name overrides."
  }
}

run "reject_other_connect_instance" {
  command = plan
  variables {
    flow = {
      name                  = "test"
      type                  = "CONTACT_FLOW"
      description           = "test"
      instance_arn          = "arn:aws:connect:us-east-1:518902362956:instance/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
      expected_instance_arn = "arn:aws:connect:us-east-1:518902362956:instance/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
      content               = "{\"StartAction\":\"original\",\"Actions\":[{\"Type\":\"DisconnectParticipant\"}]}"
    }
  }
  expect_failures = [aws_connect_contact_flow.this]
}
