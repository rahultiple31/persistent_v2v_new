mock_provider "aws" {}

mock_provider "aws" {
  alias = "us_east_1"
}

mock_provider "aws" {
  alias = "proxy_us_east_1"
}

mock_provider "external" {}

run "raw_target_is_isolated" {
  command = plan

  variables {
    enabled_modules = ["lambda-ctr-raw"]
  }

  assert {
    condition = (
      length(module.lambda-ctr-raw) == 1 &&
      length(module.lambda-ctr-survey) == 0 &&
      length(module.lambda-connect-daily-ctr-export) == 0 &&
      length(module.lambda_us_east_1) == 0 &&
      length(module.connect_us_east_1) == 0 &&
      length(module.btsgsd_support_agent) == 0 &&
      length(module.btsgsd_ai_survey_agent) == 0 &&
      length(module.s3_connect_reporting) == 0
    )
    error_message = "The raw CTR target must deploy independently of the existing Lambda, Connect, and reporting bucket targets."
  }
}

run "existing_lambda_targets_exclude_raw" {
  command = plan

  variables {
    enabled_modules = ["lambda-ctr-survey", "lambda-connect-daily-ctr-export"]
  }

  assert {
    condition = (
      length(module.lambda-ctr-survey) == 1 &&
      length(module.lambda-connect-daily-ctr-export) == 1 &&
      length(module.lambda-ctr-raw) == 0
    )
    error_message = "The existing Lambda targets must not deploy the raw CTR Lambda."
  }
}
