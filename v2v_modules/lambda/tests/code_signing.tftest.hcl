mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sts:AssumeRole\",\"Principal\":{\"Service\":\"lambda.amazonaws.com\"}}]}"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::518902362956:role/lambda-code-signing-test"
    }
  }
}

mock_provider "archive" {}

variables {
  project_name = "btsgsd"
  environment  = "v2v"
  aws_region   = "us-east-1"
  region_code  = "us-east-1"
  common_tags  = {}
}

run "associates_the_supplied_configuration" {
  command = apply

  variables {
    code_signing_config_arn = "arn:aws:lambda:us-east-1:518902362956:code-signing-config:csc-0f6c334abcdea4d8b"
  }

  assert {
    condition     = aws_lambda_function.this.code_signing_config_arn == var.code_signing_config_arn
    error_message = "The Lambda must be associated with the configuration supplied by the environment."
  }
}

run "standalone_module_without_configuration_remains_supported" {
  command = plan

  assert {
    condition     = aws_lambda_function.this.code_signing_config_arn == null
    error_message = "The reusable module must allow null; the V2V environment enforces its deployment requirement."
  }
}
