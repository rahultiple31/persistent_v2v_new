mock_provider "aws" {}

mock_provider "aws" {
  alias = "us_east_1"

  mock_data "aws_connect_instance" {
    defaults = {
      id  = "bcc989e5-cd9d-494f-9cd4-434f39ccc90e"
      arn = "arn:aws:connect:us-east-1:518902362956:instance/bcc989e5-cd9d-494f-9cd4-434f39ccc90e"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "518902362956"
    }
  }

  mock_data "aws_security_group" {
    defaults = {
      id = "sg-0aaaaaaaaaaaaaaaa"
    }
  }

  mock_data "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::518902362956:role/BTSGSD-IVA-Lambda-Warmup-Scheduler-Role"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::518902362956:role/BTSGSD-V2V-US-views-role"
    }
  }

  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-east-1:518902362956:log-group:/aws/lambda/BTSGSD-V2V-US-views"
    }
  }

  mock_resource "aws_lambda_function" {
    defaults = {
      arn = "arn:aws:lambda:us-east-1:518902362956:function:BTSGSD-V2V-US-views"
    }
  }
}

mock_provider "awscc" {
  alias = "us_east_1"
}

mock_provider "archive" {}
mock_provider "external" {}

variables {
  environment                    = "v2v"
  translation_enabled            = false
  cognito_domain_prefix          = "views-lambda-test"
  connect_instance_url           = "https://btsgsd-dev-v2v-poc-us-east-1.my.connect.aws"
  connect_instance_region        = "us-east-1"
  connect_instance_alias         = "btsgsd-dev-v2v-poc-us-east-1"
  lambda_code_signing_config_arn = "arn:aws:lambda:us-east-1:518902362956:code-signing-config:csc-07e3c2263fd84c053"
  lambda_vpc_id                  = "vpc-0bbbbbbbbbbbbbbbb"
  lambda_subnet_ids              = ["subnet-0cccccccccccccccc", "subnet-0dddddddddddddddd"]
}

# Exact names, permissions and schedule are asserted in
# v2v_modules/views_lambda/tests. These runs check the root wiring: each choice
# plans its own module, so inputs, providers and validations resolve.
run "connect_state_plans_the_views_lambda" {
  command = plan

  variables {
    enabled_modules = ["connect"]
  }

  plan_options {
    target = [module.views_lambda[0]]
  }

  assert {
    condition     = length(module.views_lambda) == 1
    error_message = "The connect state must plan the views Lambda."
  }
}

run "cloudwatch_log_group_state_plans_the_it_support_log_group_only" {
  command = plan

  variables {
    enabled_modules = ["cloudwatch_log_group"]
  }

  plan_options {
    target = [module.lex_it_support_log_group[0]]
  }

  assert {
    condition     = length(module.lex_it_support_log_group) == 1
    error_message = "The cloudwatch_log_group state must plan the IT Support log group."
  }
}
