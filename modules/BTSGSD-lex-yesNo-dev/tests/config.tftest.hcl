mock_provider "aws" {
  mock_data "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::518902362956:role/BTSGSD-lex-yesNo-role-ow5vzdof"
    }
  }

  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-east-1:518902362956:log-group:/aws/lambda/BTSGSD-lex-yesNo-dev"
    }
  }
}

variables {
  function_name  = "BTSGSD-lex-yesNo-dev"
  iam_role_name  = "BTSGSD-lex-yesNo-role-ow5vzdof"
  log_group_name = "/aws/lambda/BTSGSD-lex-yesNo-dev"
  zip_path       = "../../environments/dev/metadata/BTSGSD-lex-yesNo-dev_lambda-dev_lambda/lambda_function.zip"
  layer_arn      = "arn:aws:lambda:us-east-1:615299751070:layer:AWSOpenTelemetryDistroPython:32"

  environment_variables = {
    LOWER_THRESHOLD         = "0.4"
    UPPER_THRESHOLD         = "0.7"
    LOG_LEVEL               = "DEBUG"
    AWS_LAMBDA_EXEC_WRAPPER = "/opt/otel-instrument"
  }
}

run "prebuilt_package_and_scoped_log_access" {
  command = apply

  assert {
    condition = (
      length(aws_lambda_permission.lex_invoke) == 0 &&
      jsondecode(aws_iam_role_policy.lambda_logs.policy).Statement[0].Resource == "${aws_cloudwatch_log_group.lambda_logs.arn}:*" &&
      jsondecode(aws_iam_role_policy.lambda_logs.policy).Statement[0].Action == ["logs:CreateLogStream", "logs:PutLogEvents"] &&
      aws_lambda_function.lambda.filename == var.zip_path &&
      aws_lambda_function.lambda.source_code_hash == filebase64sha256(var.zip_path)
    )
    error_message = "Use the prebuilt ZIP, scope log access, and omit Lex invocation permission without an alias."
  }
}

run "alias_invocation_is_scoped_to_its_account" {
  command = apply

  variables {
    lex_bot_alias_arn = "arn:aws:lex:us-east-1:210987654321:bot-alias/TESTBOT123/TESTALIAS1"
  }

  assert {
    condition = (
      length(aws_lambda_permission.lex_invoke) == 1 &&
      aws_lambda_permission.lex_invoke[0].principal == "lexv2.amazonaws.com" &&
      aws_lambda_permission.lex_invoke[0].source_arn == var.lex_bot_alias_arn &&
      aws_lambda_permission.lex_invoke[0].source_account == "210987654321"
    )
    error_message = "Grant invocation only to the configured Lex alias and its account."
  }
}

run "invalid_alias_is_rejected" {
  command = plan

  variables {
    lex_bot_alias_arn = "arn:aws:lex:us-east-1:123456789012:bot/TESTBOT123"
  }

  expect_failures = [var.lex_bot_alias_arn]
}

run "requested_dev_alias_permission_and_role" {
  command = apply

  variables {
    lex_bot_alias_arn = "arn:aws:lex:us-east-1:518902362956:bot-alias/QT2GQYM5TT/6NLNDQWUJ8"
  }

  assert {
    condition = (
      aws_lambda_function.lambda.function_name == "BTSGSD-lex-yesNo-dev" &&
      aws_lambda_function.lambda.role == "arn:aws:iam::518902362956:role/BTSGSD-lex-yesNo-role-ow5vzdof" &&
      aws_lambda_permission.lex_invoke[0].statement_id == "lex-lambda-invokeFunction-QT2GQYM5TT-6NLNDQWUJ8" &&
      aws_lambda_permission.lex_invoke[0].function_name == "BTSGSD-lex-yesNo-dev" &&
      aws_lambda_permission.lex_invoke[0].principal == "lexv2.amazonaws.com" &&
      aws_lambda_permission.lex_invoke[0].action == "lambda:InvokeFunction" &&
      aws_lambda_permission.lex_invoke[0].source_account == "518902362956" &&
      aws_lambda_permission.lex_invoke[0].source_arn == var.lex_bot_alias_arn &&
      aws_lambda_permission.lex_invoke[0].qualifier == null
    )
    error_message = "The Dev Lambda must use the supplied role and grant unqualified invocation only to the requested Lex alias and account, with the supplied statement ID."
  }
}
