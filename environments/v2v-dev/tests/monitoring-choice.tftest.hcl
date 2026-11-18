mock_provider "aws" {}

mock_provider "aws" {
  alias = "us_east_1"

  mock_data "aws_connect_instance" {
    defaults = {
      id = "bcc989e5-cd9d-494f-9cd4-434f39ccc90e"
    }
  }

  mock_data "aws_lambda_function" {
    defaults = {
      timeout                        = 8
      reserved_concurrent_executions = -1
    }
  }

  mock_data "aws_cloudformation_stack" {
    defaults = {
      outputs = {
        GatewayArn = "arn:aws:bedrock-agentcore:us-east-1:518902362956:gateway/btsgsd-v2v-us-gateway-quick-start-rjqs1usbt7"
      }
    }
  }
}

mock_provider "awscc" {
  alias = "us_east_1"
}

mock_provider "archive" {}
mock_provider "external" {}

variables {
  environment             = "v2v"
  translation_enabled     = false
  cognito_domain_prefix   = "monitoring-test"
  connect_instance_url    = "https://btsgsd-dev-v2v-poc-us-east-1.my.connect.aws"
  connect_instance_region = "us-east-1"
  connect_instance_alias  = "btsgsd-dev-v2v-poc-us-east-1"
  enabled_modules         = ["monitoring"]
  lambda_vpc_id           = "vpc-0bbbbbbbbbbbbbbbb"
  lambda_subnet_ids       = ["subnet-0cccccccccccccccc"]
}

# terraform.tfvars supplies the watched resources and the subscriber.
run "monitoring_choice_plans_every_v2v_alarm_and_the_topic" {
  command = plan

  plan_options {
    target = [module.monitoring[0]]
  }

  # Names, thresholds and dimensions are asserted in v2v_modules/monitoring/tests.
  assert {
    condition = (
      length(module.monitoring) == 1 &&
      length(var.monitoring_lambda_alarms) == 18 &&
      length(var.monitoring_contact_flow_alarms) == 8 &&
      length(var.monitoring_queue_alarms) == 6
    )
    error_message = "terraform.tfvars must map 18 Lambdas, 8 flows and 6 queues (4 + 2 + 1 alarms each, plus 7 instance and 3 gateway alarms: 104)."
  }

  assert {
    condition = alltrue(flatten([
      for alarms in [var.monitoring_lambda_alarms, var.monitoring_contact_flow_alarms, var.monitoring_queue_alarms] : [
        for target, cfg in alarms : length(trimspace(cfg.alarm_label)) > 0 && !endswith(cfg.alarm_label, "-v2v")
      ]
    ]))
    error_message = "Every alarm_label must be the name part of a console alarm."
  }

  assert {
    condition     = length(var.monitoring_alert_email_addresses) > 0
    error_message = "terraform.tfvars must subscribe at least one address to the alerts topic."
  }
}

run "other_groups_plan_without_monitoring" {
  command = plan

  variables {
    enabled_modules = ["cloudwatch_log_group"]
  }

  plan_options {
    target = [module.lex_it_support_log_group[0]]
  }

  # Asserting on module.monitoring in a run that does not target it crashes
  # Terraform 1.14; the selector tests cover state ownership instead.
  assert {
    condition     = length(module.lex_it_support_log_group) == 1
    error_message = "Another group plans without the monitoring inputs."
  }
}
