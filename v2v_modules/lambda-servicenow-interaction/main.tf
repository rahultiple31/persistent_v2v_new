terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws      = { source = "hashicorp/aws", version = ">= 5.100.0, < 7.0.0" }
    archive  = { source = "hashicorp/archive", version = "~> 2.0" }
    external = { source = "hashicorp/external", version = "~> 2.3" }
  }
}

variable "common_tags" {
  type    = map(string)
  default = {}
}

variable "environment_variables" {
  type    = map(string)
  default = {}
}

variable "python_executable" {
  type    = string
  default = "python3"
}

variable "reserved_concurrency" {
  description = "Positive reserved concurrency, or null to use the shared unreserved pool."
  type        = number
  default     = 100
  nullable    = true

  validation {
    condition = var.reserved_concurrency == null ? true : (
      var.reserved_concurrency >= 1 &&
      floor(var.reserved_concurrency) == var.reserved_concurrency
    )
    error_message = "reserved_concurrency must be null or a positive whole number."
  }
}

locals {
  function_name = "BTSGSD-V2V-US-ServiceNow_Interaction"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Check capacity only when reserving executions.
data "external" "capacity" {
  count = var.reserved_concurrency == null ? 0 : 1

  program = [
    var.python_executable,
    "${path.module}/../lambda-snow-btsgsd-dev/scripts/check_capacity.py"
  ]

  query = {
    region        = data.aws_region.current.region
    account_id    = data.aws_caller_identity.current.account_id
    function_name = local.function_name
  }
}

# Packages lambda_function.py at the ZIP root.
data "archive_file" "interaction" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.root}/metadata/lambda-servicenow-interaction/${local.function_name}.zip"
}

resource "aws_cloudwatch_log_group" "interaction" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = 90
  tags              = var.common_tags
}

resource "aws_iam_role" "execution" {
  name = "${local.function_name}-role"
  tags = var.common_tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "logging" {
  name = "BTSGSD-V2V-US-servicenow-interaction-logging"
  role = aws_iam_role.execution.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.interaction.arn}:*"
    }]
  })
}

# Upload the local ZIP directly to Lambda; no S3 deployment bucket is used.
resource "aws_lambda_function" "interaction" {
  function_name                  = local.function_name
  role                           = aws_iam_role.execution.arn
  runtime                        = "python3.14"
  architectures                  = ["x86_64"]
  handler                        = "lambda_function.lambda_handler"
  package_type                   = "Zip"
  filename                       = data.archive_file.interaction.output_path
  source_code_hash               = data.archive_file.interaction.output_base64sha256
  publish                        = false
  memory_size                    = 512
  timeout                        = 8
  reserved_concurrent_executions = var.reserved_concurrency == null ? -1 : var.reserved_concurrency
  tags                           = var.common_tags

  ephemeral_storage {
    size = 512
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.interaction.name
  }

  environment {
    variables = merge({
      SN_INSTANCE = "abbvienowdev"
      SN_CTI_RULE = "cti_gsd"
    }, var.environment_variables)
  }
  lifecycle {
    precondition {
      condition = var.reserved_concurrency == null ? true : (
        tonumber(data.external.capacity[0].result.maximum_reservation) >= var.reserved_concurrency
      )
      error_message = "Requested reserved concurrency exceeds available regional capacity. Increase the quota, release other reservations, or set reserved_concurrency to null."
    }

    precondition {
      condition     = data.archive_file.interaction.output_size <= 50 * 1024 * 1024
      error_message = "Direct Lambda uploads require a ZIP package no larger than 50 MiB."
    }
  }

  depends_on = [aws_iam_role_policy.logging]
}

resource "aws_lambda_permission" "interaction_connect" {
  statement_id  = "connect-c227a737-3e4f-4c64-8397-2d37e318801d"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.interaction.function_name
  principal     = "connect.amazonaws.com"

  source_account = "518902362956"
  source_arn     = "arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d"
}

resource "aws_lambda_permission" "interaction_agentcore" {
  statement_id  = "servicenow_interaction_btsgsd_dev_agent"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.interaction.function_name
  principal     = "bedrock-agentcore.amazonaws.com"

  source_arn = "arn:aws:wisdom:us-east-1:518902362956:ai-agent/bc274e3f-380d-45e7-968f-2d19f92acd74/c1c0c6cf-2e49-4091-bb06-85f9e7095a96:$SAVED"
}

output "deployment" {
  value = {
    function_name = aws_lambda_function.interaction.function_name
    function_arn  = aws_lambda_function.interaction.arn
    log_group     = aws_cloudwatch_log_group.interaction.name
  }
}
