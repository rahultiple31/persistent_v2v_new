data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

# Only needed when reserving concurrency; skipped when var.reserved_concurrency is null.
data "external" "capacity" {
  count   = var.reserved_concurrency == null ? 0 : 1
  program = [var.python_executable, "${path.module}/scripts/check_capacity.py"]

  query = {
    region        = data.aws_region.current.region
    account_id    = data.aws_caller_identity.current.account_id
    function_name = var.function_name
  }
}

# Package ./src with lambda_function.py at the ZIP root.
data "archive_file" "snow" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.root}/metadata/lambda-snow-btsgsd-dev/${var.function_name}.zip"
}

resource "aws_cloudwatch_log_group" "snow" {
  name              = "/aws/lambda/${var.function_name}"
  retention_in_days = var.log_retention_days
  tags              = var.common_tags
}

data "aws_iam_role" "execution" {
  name = "SNOW_btsgsd-dev-lambda-role"
}

# Preserve any previously managed role when switching to the existing role.
removed {
  from = aws_iam_role.execution

  lifecycle {
    destroy = false
  }
}

resource "aws_iam_role_policy" "logging" {
  name = "BTSGSD-V2V-US-snow-cloudwatch-logs"
  role = data.aws_iam_role.execution.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.snow.arn}:*"
    }]
  })
}

module "application_signals" {
  source    = "../lambda-application-signals"
  role_name = data.aws_iam_role.execution.name
}

# Upload the local ZIP directly to Lambda; no S3 deployment bucket is used.
resource "aws_lambda_function" "snow" {
  code_signing_config_arn = var.code_signing_config_arn

  layers = [module.application_signals.layer_arn]

  tracing_config {
    mode = "Active"
  }

  function_name                  = var.function_name
  role                           = data.aws_iam_role.execution.arn
  runtime                        = "python3.13"
  architectures                  = ["x86_64"]
  handler                        = "lambda_function.lambda_handler"
  package_type                   = "Zip"
  filename                       = data.archive_file.snow.output_path
  source_code_hash               = data.archive_file.snow.output_base64sha256
  memory_size                    = 512
  timeout                        = 8
  reserved_concurrent_executions = var.reserved_concurrency == null ? -1 : var.reserved_concurrency
  tags                           = var.common_tags
  publish                        = true

  snap_start {
    apply_on = "PublishedVersions"
  }

  ephemeral_storage {
    size = 512
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.snow.name
  }

  environment {
    variables = merge(var.environment_variables, module.application_signals.environment_variables)
  }
  lifecycle {
    precondition {
      condition = var.reserved_concurrency == null ? true : (
        tonumber(data.external.capacity[0].result.maximum_reservation) >= var.reserved_concurrency
      )
      error_message = "Requested reserved concurrency exceeds available regional capacity. Increase the quota, release other reservations, or set reserved_concurrency to null."
    }

    precondition {
      condition     = data.archive_file.snow.output_size <= 50 * 1024 * 1024
      error_message = "Direct Lambda uploads require a ZIP package no larger than 50 MiB."
    }
  }

  depends_on = [aws_iam_role_policy.logging]
}

resource "aws_lambda_runtime_management_config" "snow" {
  function_name     = aws_lambda_function.snow.function_name
  update_runtime_on = "Auto"
}

resource "aws_lambda_permission" "snow_connect" {
  statement_id  = "connect-c227a737-3e4f-4c64-8397-2d37e318801d"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.snow.function_name
  principal     = "connect.amazonaws.com"

  source_account = "518902362956"
  source_arn     = "arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d"
}

resource "aws_lambda_permission" "snow_agentcore" {
  statement_id  = "servicenow_btsgsd_dev_agent"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.snow.function_name
  principal     = "bedrock-agentcore.amazonaws.com"

  source_arn = "arn:aws:wisdom:us-east-1:518902362956:ai-agent/bc274e3f-380d-45e7-968f-2d19f92acd74/c1c0c6cf-2e49-4091-bb06-85f9e7095a96:$SAVED"
}
