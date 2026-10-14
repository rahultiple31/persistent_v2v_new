mock_provider "aws" {}

mock_provider "aws" {
  alias = "us_east_1"
}

mock_provider "aws" {
  alias = "proxy_us_east_1"
}

mock_provider "external" {
  mock_data "external" {
    defaults = {
      result = {
        unreserved          = "200"
        current_reservation = "0"
        maximum_reservation = "100"
      }
    }
  }
}

run "interaction_target_is_isolated" {
  command = plan

  variables {
    enabled_modules = ["lambda-servicenow-interaction"]
  }

  assert {
    condition = (
      length(module.lambda-servicenow-interaction) == 1 &&
      length(module.lambda-snow-btsgsd-dev) == 0 &&
      length(module.lambda_us_east_1) == 0 &&
      length(module.lambda-ctr-survey) == 0 &&
      length(module.lambda-ctr-raw) == 0 &&
      length(module.lambda-connect-daily-ctr-export) == 0 &&
      length(module.connect_us_east_1) == 0 &&
      length(module.agentcore_gateway) == 0 &&
      length(aws_cloudformation_stack.customer_number_data_table) == 0
    )
    error_message = "The Interaction target must deploy independently of the existing Lambda, Connect and gateway targets."
  }
}

run "existing_lambda_target_excludes_interaction" {
  command = plan

  variables {
    enabled_modules = ["lambda-snow-btsgsd-dev"]
  }

  assert {
    condition     = length(module.lambda-servicenow-interaction) == 0 && output.servicenow_interaction_lambda == null
    error_message = "Existing deployment targets must not deploy the new Interaction Lambda implicitly."
  }
}
