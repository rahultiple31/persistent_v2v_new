mock_provider "aws" {
  mock_data "aws_connect_instance" {
    defaults = {
      id = "11111111-2222-3333-4444-555555555555"
    }
  }
}

run "survey_uses_resolved_dev_instance" {
  command = plan

  module {
    source = "../../modules/lambda-ctr-survey"
  }

  variables {
    source_file = abspath("metadata/lambda-ctr/lambda_function_ctr_.py")
  }

  assert {
    condition = (
      data.aws_connect_instance.selected.instance_alias == "btsgsd-dev-us-east-1" &&
      aws_lambda_function.survey.environment[0].variables["CONNECT_INSTANCE_ID"] == "11111111-2222-3333-4444-555555555555" &&
      aws_lambda_function.survey.environment[0].variables["S3_BUCKET"] == "btsgsd-dev-us-east-1-connect-reporting-bucket" &&
      aws_lambda_function.survey.environment[0].variables["BUSINESS_TIMEZONE"] == "America/Chicago"
    )
    error_message = "Survey must resolve the dev Connect alias to its ID and preserve the existing environment."
  }
}

run "daily_export_uses_resolved_dev_instance" {
  command = plan

  module {
    source = "../../modules"
  }

  variables {
    source_file = abspath("metadata/lambda-ctr/lambda_function_ctr_export.py")
  }

  assert {
    condition = (
      data.aws_connect_instance.selected.instance_alias == "btsgsd-dev-us-east-1" &&
      aws_lambda_function.export.environment[0].variables["CONNECT_INSTANCE_ID"] == "11111111-2222-3333-4444-555555555555" &&
      aws_lambda_function.export.environment[0].variables["FILE_PREFIX"] == "abbvieacd" &&
      aws_lambda_function.export.environment[0].variables["SHORT_ABANDON_SECONDS"] == "10"
    )
    error_message = "Daily export must resolve the dev Connect alias to its ID and preserve export settings."
  }
}

run "raw_uses_resolved_dev_instance" {
  command = plan

  module {
    source = "../../modules/lambda-ctr-raw"
  }

  variables {
    source_file = abspath("metadata/lambda-ctr/lambda_function_ctr_raw.py")
  }

  assert {
    condition = (
      data.aws_connect_instance.selected.instance_alias == "btsgsd-dev-us-east-1" &&
      aws_lambda_function.raw.environment[0].variables["CONNECT_INSTANCE_ID"] == "11111111-2222-3333-4444-555555555555" &&
      aws_lambda_function.raw.environment[0].variables["OUTPUT_FILE_NAME"] == "test.csv"
    )
    error_message = "Raw CTR must resolve the dev Connect alias to its ID and preserve the output file name."
  }
}

run "resolved_instance_overrides_stale_environment_id" {
  command = plan

  module {
    source = "../../modules/lambda-ctr-raw"
  }

  variables {
    source_file            = abspath("metadata/lambda-ctr/lambda_function_ctr_raw.py")
    connect_instance_alias = "test-connect-alias"
    environment_variables = {
      CONNECT_INSTANCE_ID = "stale-instance-id"
      S3_BUCKET           = "test-reporting-bucket"
      S3_PREFIX           = "test-prefix"
      OUTPUT_FILE_NAME    = "custom.csv"
    }
  }

  assert {
    condition = (
      data.aws_connect_instance.selected.instance_alias == "test-connect-alias" &&
      aws_lambda_function.raw.environment[0].variables["CONNECT_INSTANCE_ID"] == "11111111-2222-3333-4444-555555555555" &&
      aws_lambda_function.raw.environment[0].variables["OUTPUT_FILE_NAME"] == "custom.csv"
    )
    error_message = "The resolved instance ID must override stale environment values without losing custom settings."
  }
}
