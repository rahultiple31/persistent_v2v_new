locals {
  function_name = lower(replace(var.name_prefix == null ? "${var.project_name}-${var.environment}-${var.lambda_name_suffix}" : "${var.name_prefix}-${var.lambda_name_suffix}", "_", "-"))
  role_name     = lower(replace(var.name_prefix == null ? "${var.project_name}-${var.environment}-${var.region_code}-${var.lambda_name_suffix}-role" : "${var.name_prefix}-${var.lambda_name_suffix}-role", "_", "-"))
  tags = merge(var.common_tags, {
    Name       = local.function_name
    RegionCode = var.region_code
    AWSRegion  = var.aws_region
    Service    = var.lambda_name_suffix
    Temporary  = "true"
  })
}

data "archive_file" "function" {
  type        = "zip"
  output_path = "${path.root}/${local.role_name}.zip"

  source_content = <<-PY
import json


def handler(event, context):
    return {
        "statusCode": 200,
        "body": json.dumps({
            "message": "Lambda pipeline test successful",
            "region": "${var.aws_region}",
            "environment": "${var.environment}"
        })
    }
  PY

  source_content_filename = "lambda_function.py"
}

data "aws_iam_policy_document" "assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = local.role_name
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "basic_execution" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

resource "aws_lambda_function" "this" {
  function_name    = local.function_name
  role             = aws_iam_role.this.arn
  handler          = "lambda_function.handler"
  runtime          = var.runtime
  filename         = data.archive_file.function.output_path
  source_code_hash = data.archive_file.function.output_base64sha256
  timeout          = var.timeout
  memory_size      = var.memory_size

  tags = local.tags

  depends_on = [
    aws_cloudwatch_log_group.this,
    aws_iam_role_policy_attachment.basic_execution
  ]
}
