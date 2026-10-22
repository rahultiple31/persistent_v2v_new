mock_provider "aws" {
  mock_data "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/conversionOfQueueMetrics-role-ox32eazp"
    }
  }

  mock_data "aws_dynamodb_table" {
    defaults = {
      arn = "arn:aws:dynamodb:us-east-1:123456789012:table/queueInfo"
    }
  }

  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-east-1:123456789012:log-group:/aws/lambda/conversionOfQueueMetrics-dev"
    }
  }
}

variables {
  function_name  = "BTSGSD-V2V-US-conversionOfQueueMetrics"
  iam_role_name  = "conversionOfQueueMetrics-role-ox32eazp"
  log_group_name = "/aws/lambda/BTSGSD-V2V-US-conversionOfQueueMetrics"
  zip_path       = "../../environments/v2v/metadata/conversionOfQueueMetrics-dev_lambda/lambda_function.zip"

  environment_variables = {
    TableName   = "queueInfo"
    LOG_LEVEL   = "DEBUG"
    TTL_SECONDS = "86400"
  }
}

run "prebuilt_zip_and_scoped_permissions" {
  command = apply

  assert {
    condition = (
      jsondecode(aws_iam_role_policy.lambda_access.policy).Statement[0].Resource == data.aws_dynamodb_table.queue_info.arn &&
      jsondecode(aws_iam_role_policy.lambda_access.policy).Statement[0].Action == ["dynamodb:GetItem", "dynamodb:UpdateItem"] &&
      jsondecode(aws_iam_role_policy.lambda_access.policy).Statement[1].Resource == "${aws_cloudwatch_log_group.lambda_logs.arn}:*" &&
      output.lambda_name == "BTSGSD-V2V-US-conversionOfQueueMetrics" &&
      aws_lambda_function.lambda.filename == var.zip_path &&
      aws_lambda_function.lambda.source_code_hash == filebase64sha256(var.zip_path)
    )
    error_message = "Use the supplied ZIP and scope its permissions to the configured table and log group."
  }
}
