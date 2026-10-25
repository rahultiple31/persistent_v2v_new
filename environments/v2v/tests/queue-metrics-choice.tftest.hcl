mock_provider "aws" {}

mock_provider "aws" {
  alias = "us_east_1"

  mock_data "aws_connect_instance" {
    defaults = {
      id  = "bcc989e5-cd9d-494f-9cd4-434f39ccc90e"
      arn = "arn:aws:connect:us-east-1:518902362956:instance/bcc989e5-cd9d-494f-9cd4-434f39ccc90e"
    }
  }

  mock_data "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::518902362956:role/conversionOfQueueMetrics-role-ox32eazp"
    }
  }

  mock_data "aws_dynamodb_table" {
    defaults = {
      arn = "arn:aws:dynamodb:us-east-1:518902362956:table/BTSGSD-V2V-US-queueInfo"
    }
  }

  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-east-1:518902362956:log-group:/aws/lambda/BTSGSD-V2V-US-conversionOfQueueMetrics"
    }
  }
}

mock_provider "awscc" {
  alias = "us_east_1"
}
mock_provider "archive" {}
mock_provider "external" {}

run "queue_metrics_choice_includes_scoped_invocation_permission" {
  command = plan

  variables {
    environment                    = "v2v"
    translation_enabled            = false
    cognito_domain_prefix          = "queue-metrics-test"
    connect_instance_url           = "https://btsgsd-dev-v2v-poc-us-east-1.my.connect.aws"
    connect_instance_region        = "us-east-1"
    enabled_modules                = ["connect"]
    connect_instance_alias         = "btsgsd-dev-v2v-poc-us-east-1"
    lambda_code_signing_config_arn = "arn:aws:lambda:us-east-1:518902362956:code-signing-config:csc-07e3c2263fd84c053"
  }

  plan_options {
    target = [module.conversion_of_queue_metrics[0], aws_lambda_permission.queue_metrics_connect[0]]
  }

  assert {
    condition     = aws_lambda_permission.queue_metrics_connect[0].function_name == "BTSGSD-V2V-US-conversionOfQueueMetrics"
    error_message = "The invocation grant must target the V2V Lambda, not the legacy dev function."
  }

  assert {
    condition = (
      aws_lambda_permission.queue_metrics_connect[0].statement_id == "AllowConnectCustomerQueueMetrics" &&
      aws_lambda_permission.queue_metrics_connect[0].action == "lambda:InvokeFunction" &&
      aws_lambda_permission.queue_metrics_connect[0].principal == "connect.amazonaws.com" &&
      aws_lambda_permission.queue_metrics_connect[0].source_account == "518902362956" &&
      aws_lambda_permission.queue_metrics_connect[0].source_arn == "arn:aws:connect:us-east-1:518902362956:instance/bcc989e5-cd9d-494f-9cd4-434f39ccc90e"
    )
    error_message = "The single Connect grant must be restricted to the selected V2V instance and account."
  }
}
