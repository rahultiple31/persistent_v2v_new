mock_provider "aws" {}

mock_provider "aws" {
  alias = "us_east_1"
}

mock_provider "aws" {
  alias = "proxy_us_east_1"
}

mock_provider "external" {}

run "survey_target_is_isolated" {
  command = plan

  override_data {
    target = module.lambda-ctr-survey[0].data.archive_file.survey
    values = {
      output_path         = "ctr-survey-test.zip"
      output_base64sha256 = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    }
  }

  variables {
    enabled_modules = ["lambda-ctr-survey"]
  }

  assert {
    condition = (
      length(module.lambda-ctr-survey) == 1 &&
      length(module.lambda_us_east_1) == 0 &&
      length(module.connect_us_east_1) == 0 &&
      length(module.btsgsd_support_agent) == 0 &&
      length(module.btsgsd_ai_survey_agent) == 0 &&
      length(module.s3_connect_reporting) == 0
    )
    error_message = "The CTR survey target must deploy independently of the Connect, test Lambda, and reporting bucket targets."
  }
}

run "reporting_bucket_excludes_survey_lambda" {
  command = plan

  variables {
    enabled_modules = ["s3_connect_reporting"]
  }

  assert {
    condition     = length(module.s3_connect_reporting) == 1 && length(module.lambda-ctr-survey) == 0
    error_message = "The reporting bucket target must not deploy the CTR survey Lambda."
  }
}
