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
        unreserved          = "300"
        current_reservation = "0"
        maximum_reservation = "200"
      }
    }
  }
}

run "nextthink_target_is_isolated" {
  command = plan

  variables {
    enabled_modules = ["lambda-nextthink-handoff"]
  }

  assert {
    condition = (
      length(module.lambda-nextthink-handoff) == 1 &&
      length(module.lambda-servicenow-interaction) == 0 &&
      length(module.lambda-snow-btsgsd-dev) == 0 &&
      length(module.lambda_us_east_1) == 0 &&
      length(module.lambda-ctr-survey) == 0 &&
      length(module.lambda-ctr-raw) == 0 &&
      length(module.lambda-connect-daily-ctr-export) == 0 &&
      length(module.connect_us_east_1) == 0 &&
      length(module.agentcore_gateway) == 0 &&
      length(aws_cloudformation_stack.customer_number_data_table) == 0
    )
    error_message = "The Nexthink target must deploy independently of the existing Lambda and Connect targets."
  }
}

run "interaction_target_excludes_nextthink" {
  command = plan

  variables {
    enabled_modules = ["lambda-servicenow-interaction"]
  }

  assert {
    condition = (
      length(module.lambda-servicenow-interaction) == 1 &&
      length(module.lambda-nextthink-handoff) == 0 &&
      output.nexthink_handoff_lambda == null
    )
    error_message = "Deploying Interaction must not deploy Nexthink implicitly."
  }
}
