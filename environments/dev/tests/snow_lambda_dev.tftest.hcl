mock_provider "aws" {}

mock_provider "aws" {
  alias = "us_east_1"
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sts:AssumeRole\",\"Principal\":{\"Service\":\"lambda.amazonaws.com\"}}]}"
    }
  }
}

mock_provider "aws" {
  alias = "proxy_us_east_1"
}

mock_provider "external" {
  mock_data "external" {
    defaults = {
      result = {
        unreserved          = "400"
        current_reservation = "0"
        maximum_reservation = "300"
      }
    }
  }
}

run "snow_dev_target_is_isolated" {
  command = plan
  variables {
    enabled_modules = ["lambda-snow-btsgsd-dev"]
  }
  assert {
    condition = (
      length(module.lambda-snow-btsgsd-dev) == 1 &&
      length(module.lambda_us_east_1) == 0 &&
      length(module.lambda-ctr-survey) == 0 &&
      length(module.lambda-ctr-raw) == 0 &&
      length(module.lambda-connect-daily-ctr-export) == 0 &&
      length(module.connect_us_east_1) == 0 &&
      length(module.btsgsd_support_agent) == 0 &&
      length(module.btsgsd_ai_survey_agent) == 0
    )
    error_message = "Deploy SNOW_btsgsd-dev independently of existing Lambda, Connect and AI resources."
  }
}

run "existing_lambda_targets_exclude_snow_dev" {
  command = plan
  variables {
    enabled_modules = ["lambda", "lambda-ctr-survey", "lambda-ctr-raw", "lambda-connect-daily-ctr-export"]
  }
  assert {
    condition     = length(module.lambda-snow-btsgsd-dev) == 0 && output.snow_lambda_dev == null
    error_message = "Existing Lambda targets must not deploy SNOW_btsgsd-dev implicitly."
  }
}
