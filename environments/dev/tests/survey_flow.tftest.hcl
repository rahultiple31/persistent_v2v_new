mock_provider "aws" {}
mock_provider "aws" {
  alias = "us_east_1"
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1", name = "us-east-1" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "518902362956" }
  }
  mock_data "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::518902362956:role/conversionOfQueueMetrics-role-ox32eazp" }
  }
  mock_resource "aws_cloudformation_stack" {
    defaults = {
      outputs = {
        DataTableArn = "arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d/data-table/11111111-1111-1111-1111-111111111111"
      }
    }
  }
}
mock_provider "aws" { alias = "proxy_us_east_1" }
mock_provider "awscc" { alias = "us_east_1" }
mock_provider "archive" {}
mock_provider "time" {}
mock_provider "external" {
  mock_data "external" {
    defaults = {
      result = { content = "{\"Version\":\"2019-10-30\",\"StartAction\":\"done\",\"Actions\":[{\"Identifier\":\"done\",\"Type\":\"DisconnectParticipant\",\"Parameters\":{},\"Transitions\":{}}]}" }
    }
  }
}

override_module {
  target = module.abbvie_views[0]
  outputs = {
    flow_arn  = "arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d/contact-flow/55555555-5555-5555-5555-555555555555"
    flow_id   = "55555555-5555-5555-5555-555555555555"
    flow_name = "AbbVie_Views"
  }
}

variables {
  cognito_domain_prefix                 = "survey-flow-test"
  connect_instance_url                  = "https://survey-test.my.connect.aws"
  connect_instance_region               = "us-east-1"
  connect_admin_user_enabled            = false
  dev_ai_domain_enabled                 = false
  dev_ai_assistant_id                   = "160889f7-d564-47fb-97db-94549fc55993"
  dev_ai_agent_enabled                  = false
  dev_support_ai_agent_enabled          = false
  dev_survey_ai_agent_enabled           = false
  dev_ai_admin_security_profile_enabled = false
}

run "new_survey_and_inbound_plan_together" {
  command = plan
  variables { enabled_modules = ["connect"] }

  plan_options {
    target = [
      aws_connect_contact_flow.survey,
      module.connect_us_east_1[0].aws_connect_contact_flow.imported_main_inbound
    ]
  }

  assert {
    condition = (
      length(aws_connect_contact_flow.survey) == 1 &&
      aws_connect_contact_flow.survey[0].name == "BTSGSD-AIAgent-SurveyFlow" &&
      aws_connect_contact_flow.survey[0].type == "CONTACT_FLOW"
    )
    error_message = "The survey and inbound flow must plan together while the new survey ARN is still unknown."
  }

  assert {
    condition = (
      local.rendered_imported_contact_flows.customer_queue.name == "BTSGSD_Abbvie_CustomerQueueFlow" &&
      local.rendered_imported_contact_flows.customer_queue.type == "CUSTOMER_QUEUE" &&
      length(aws_lambda_permission.queue_metrics_connect) == 1 &&
      length(aws_connect_lambda_function_association.queue_metrics) == 1 &&
      aws_lambda_permission.queue_metrics_connect[0].principal == "connect.amazonaws.com"
    )
    error_message = "Connect deployment must retain the customer-queue resource while granting and associating the Dev metrics Lambda."
  }
}

run "non_connect_skips_survey" {
  command = plan
  variables { enabled_modules = [] }

  assert {
    condition = (
      length(aws_connect_contact_flow.survey) == 0 &&
      length(data.external.survey_flow_dependencies) == 0 &&
      length(aws_lambda_permission.queue_metrics_connect) == 0 &&
      length(aws_connect_lambda_function_association.queue_metrics) == 0 &&
      output.survey_flow_arn == null
    )
    error_message = "Non-Connect deployments must not create the survey or run its resolver."
  }
}
