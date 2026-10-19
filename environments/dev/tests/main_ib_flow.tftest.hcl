mock_provider "aws" {}
mock_provider "aws" {
  alias = "us_east_1"
  mock_data "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::518902362956:role/test-lambda-role" }
  }
  mock_data "aws_lambda_function" {
    defaults = {
      function_name = "SNOW_Abbvie"
      arn           = "arn:aws:lambda:us-east-1:518902362956:function:SNOW_Abbvie"
    }
  }
  mock_data "aws_connect_queue" {
    defaults = {
      arn = "arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d/queue/22222222-2222-2222-2222-222222222222"
    }
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
  target = module.connect_us_east_1[0]
  outputs = {
    instance_id             = "c227a737-3e4f-4c64-8397-2d37e318801d"
    instance_arn            = "arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d"
    customer_queue_flow_arn = "arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d/contact-flow/33333333-3333-3333-3333-333333333333"
    queue_id                = "33333333-3333-3333-3333-333333333333"
    routing_profile_id      = "33333333-3333-3333-3333-333333333333"
    admin_user_id           = null
  }
}
override_module {
  target = module.connect_queue[0]
  outputs = {
    queue_arn             = "arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d/queue/44444444-4444-4444-4444-444444444444"
    queue_id              = "44444444-4444-4444-4444-444444444444"
    hours_of_operation_id = "44444444-4444-4444-4444-444444444444"
    quick_connect_ids     = {}
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
override_module {
  target = module.UpdateSessionAttributes-dev[0]
  outputs = {
    lambda_name = "UpdateSessionAttributes-dev"
    lambda_arn  = "arn:aws:lambda:us-east-1:518902362956:function:UpdateSessionAttributes-dev"
  }
}
override_module {
  target = module.silence_guard-dev[0]
  outputs = {
    function_name = "silence_guard-dev"
    function_arn  = "arn:aws:lambda:us-east-1:518902362956:function:silence_guard-dev"
  }
}
override_module {
  target = module.conversion_of_queue_metrics[0]
  outputs = {
    lambda_name = "conversionOfQueueMetrics-dev"
    lambda_arn  = "arn:aws:lambda:us-east-1:518902362956:function:conversionOfQueueMetrics-dev"
  }
}

variables {
  cognito_domain_prefix                 = "main-ib-test"
  connect_instance_url                  = "https://main-ib-test.my.connect.aws"
  connect_instance_region               = "us-east-1"
  connect_admin_user_enabled            = false
  dev_ai_domain_enabled                 = false
  dev_ai_assistant_id                   = "160889f7-d564-47fb-97db-94549fc55993"
  dev_ai_agent_enabled                  = false
  dev_support_ai_agent_enabled          = false
  dev_survey_ai_agent_enabled           = false
  dev_ai_admin_security_profile_enabled = false
}

run "main_inbound_module_is_included" {
  command = plan
  variables { enabled_modules = ["connect"] }
  plan_options { target = [module.btsgsd-Main-IB-Flow] }

  assert {
    condition     = length(module.btsgsd-Main-IB-Flow) == 1
    error_message = "The Connect selection must include the main inbound module."
  }
}

run "non_connect_skips_main_inbound" {
  command = plan
  variables { enabled_modules = [] }
  assert {
    condition     = length(module.btsgsd-Main-IB-Flow) == 0 && output.main_inbound_flow_arn == null
    error_message = "Other deployment selections must skip the inbound flow module."
  }
}
