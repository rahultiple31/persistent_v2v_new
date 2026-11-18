mock_provider "aws" {
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::518902362956:role/mock-lex-role", name = "mock-lex-role" }
  }
  mock_resource "aws_lexv2models_bot" {
    defaults = { id = "ITSUPPORT1" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1", name = "us-east-1" }
  }
}
mock_provider "awscc" {}

# Plan only: the module's AWS CLI provisioner must never run.
variables {
  bot_name       = "BTSGSD-V2V-US-IT-Support_Agent"
  child_directed = true
  locale_ids     = ["en_US", "hi_IN", "pt_BR", "es_419"]
  it_support_configuration = {
    assistant_arn        = "arn:aws:wisdom:us-east-1:518902362956:assistant/e36d6b86-c3f5-4d6d-b85b-e44f7e7ec04f"
    connect_instance_arn = "arn:aws:connect:us-east-1:518902362956:instance/bcc989e5-cd9d-494f-9cd4-434f39ccc90e"
    alias_name           = "btsgsd-alias-dev-sso"
  }
}

run "q_in_connect_policy_is_scoped_to_the_configured_assistant" {
  command = plan

  assert {
    condition = alltrue([
      for statement in jsondecode(aws_iam_role_policy.it_support_qinconnect[0].policy).Statement :
      alltrue([for resource in statement.Resource : strcontains(resource, "e36d6b86-c3f5-4d6d-b85b-e44f7e7ec04f")])
    ])
    error_message = "Every Q in Connect permission must name the configured assistant."
  }
  assert {
    condition     = jsondecode(terraform_data.it_support_configuration[0].triggers_replace.configuration).connect_instance_arn == var.it_support_configuration.connect_instance_arn
    error_message = "The configure script must receive the configured Connect instance."
  }
}

run "assistant_must_be_an_assistant_arn" {
  command = plan
  variables {
    it_support_configuration = {
      assistant_arn        = "arn:aws:wisdom:us-east-1:518902362956:ai-agent/e36d6b86-c3f5-4d6d-b85b-e44f7e7ec04f/x"
      connect_instance_arn = "arn:aws:connect:us-east-1:518902362956:instance/bcc989e5-cd9d-494f-9cd4-434f39ccc90e"
      alias_name           = "btsgsd-alias-dev-sso"
    }
  }
  expect_failures = [var.it_support_configuration]
}

run "instance_must_be_an_instance_arn" {
  command = plan
  variables {
    it_support_configuration = {
      assistant_arn        = "arn:aws:wisdom:us-east-1:518902362956:assistant/e36d6b86-c3f5-4d6d-b85b-e44f7e7ec04f"
      connect_instance_arn = "bcc989e5-cd9d-494f-9cd4-434f39ccc90e"
      alias_name           = "btsgsd-alias-dev-sso"
    }
  }
  expect_failures = [var.it_support_configuration]
}
