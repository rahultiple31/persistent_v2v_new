mock_provider "aws" {
  mock_data "aws_connect_instance" {
    defaults = {
      id  = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
      arn = "arn:aws:connect:us-east-1:518902362956:instance/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    }
  }
}

mock_provider "external" {}

variables {
  project_name          = "btsgsd"
  environment           = "v2v"
  aws_region            = "us-east-1"
  region_code           = "us-east-1"
  common_tags           = {}
  contact_center_alias  = "btsgsd"
  instance_alias        = "btsgsd-dev-v2v-poc-us-east-1"
  expected_instance_arn = "arn:aws:connect:us-east-1:518902362956:instance/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
}

run "resources_use_the_existing_poc_instance" {
  command = plan

  assert {
    condition = (
      data.aws_connect_instance.this.instance_alias == "btsgsd-dev-v2v-poc-us-east-1" &&
      output.instance_id == "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" &&
      output.instance_arn == var.expected_instance_arn &&
      aws_connect_security_profile.agent.instance_id == output.instance_id &&
      aws_connect_contact_flow.placeholder.instance_id == output.instance_id
    )
    error_message = "Look up the existing POC alias and use its returned ID for every managed Connect resource."
  }

  assert {
    condition = alltrue([
      startswith(aws_connect_security_profile.agent.name, "BTSGSD-V2V-US-"),
      startswith(aws_connect_contact_flow.placeholder.name, "BTSGSD-V2V-US-")
    ])
    error_message = "Name new resources with the V2V prefix while reusing the existing instance alias."
  }
}

run "admin_user_uses_us_agent_routing_profile" {
  command = plan

  variables {
    admin_user_enabled    = true
    admin_user_first_name = "Admin"
    admin_user_last_name  = "User"
    admin_user_username   = "admin@example.com"
    admin_user_email      = "admin@example.com"
  }

  override_data {
    target = data.aws_connect_routing_profile.admin[0]
    values = { routing_profile_id = "48a9cf8d-1538-4184-a03e-c04912acdc3f" }
  }

  assert {
    condition = (
      data.aws_connect_routing_profile.admin[0].name == "BTSGSD-V2V-US-AGENT-RP" &&
      aws_connect_user.admin[0].routing_profile_id == "48a9cf8d-1538-4184-a03e-c04912acdc3f"
    )
    error_message = "The optional admin user must use BTSGSD-V2V-US-AGENT-RP (the primary routing profile is retired)."
  }
}

run "unexpected_instance_is_rejected" {
  command = plan

  variables {
    expected_instance_arn = "arn:aws:connect:us-east-1:518902362956:instance/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
  }

  expect_failures = [data.aws_connect_instance.this]
}
