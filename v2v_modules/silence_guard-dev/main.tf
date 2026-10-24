terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.21.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  function_name = "BTSGSD-V2V-US-silence_guard"
}

data "archive_file" "code" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.root}/metadata/${local.function_name}.zip"
}

resource "aws_cloudwatch_log_group" "this" {
  name = "/aws/lambda/${local.function_name}"
  tags = var.common_tags
}

resource "aws_iam_role" "execution" {
  name = "${local.function_name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy" "logging" {
  name = "${local.function_name}-logging"
  role = aws_iam_role.execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
      ]
      Resource = "${aws_cloudwatch_log_group.this.arn}:*"
    }]
  })
}

# Allow IAM propagation before the first function creation.
resource "time_sleep" "execution_role_ready" {
  create_duration = "60s"

  triggers = {
    role_id = aws_iam_role.execution.unique_id
  }

  depends_on = [aws_iam_role_policy.logging]
}

module "application_signals" {
  source    = "../lambda-application-signals"
  role_name = aws_iam_role.execution.name
}

resource "aws_lambda_function" "this" {
  code_signing_config_arn = var.code_signing_config_arn

  layers = [module.application_signals.layer_arn]

  tracing_config {
    mode = "Active"
  }

  function_name                  = local.function_name
  role                           = aws_iam_role.execution.arn
  runtime                        = "python3.13"
  architectures                  = ["x86_64"]
  handler                        = "lambda_function.lambda_handler"
  package_type                   = "Zip"
  filename                       = data.archive_file.code.output_path
  source_code_hash               = data.archive_file.code.output_base64sha256
  memory_size                    = 128
  timeout                        = 3
  reserved_concurrent_executions = -1

  ephemeral_storage {
    size = 512
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.this.name
  }

  environment {
    variables = merge({
      STRICT_MODE = "false"
    }, module.application_signals.environment_variables)
  }

  tags = var.common_tags

  depends_on = [
    time_sleep.execution_role_ready,
    aws_cloudwatch_log_group.this,
  ]
}

resource "aws_lambda_runtime_management_config" "this" {
  function_name     = aws_lambda_function.this.function_name
  update_runtime_on = "Auto"
}

resource "aws_lambda_permission" "connect" {
  statement_id   = "AllowAmazonConnect"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.this.function_name
  principal      = "connect.amazonaws.com"
  source_arn     = var.connect_instance_arn
  source_account = data.aws_caller_identity.current.account_id
}

resource "aws_connect_lambda_function_association" "this" {
  instance_id  = element(reverse(split("/", var.connect_instance_arn)), 0)
  function_arn = aws_lambda_function.this.arn

  depends_on = [aws_lambda_permission.connect]
}
