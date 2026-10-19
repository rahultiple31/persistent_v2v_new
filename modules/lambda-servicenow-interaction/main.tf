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
  function_name = "ServiceNow_Interaction_btsgsd-dev"
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
  output_path = "${path.root}/${local.function_name}.zip"
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
  name = "servicenow-interaction-logging"
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

resource "aws_s3_bucket" "code" {
  bucket_prefix = "servicenow-interaction-dev-code-"
  tags          = var.common_tags
}

resource "aws_s3_bucket_public_access_block" "code" {
  bucket                  = aws_s3_bucket.code.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "code" {
  bucket = aws_s3_bucket.code.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_object" "code" {
  bucket                 = aws_s3_bucket.code.id
  key                    = "interaction/${data.archive_file.interaction.output_sha256}.zip"
  source                 = data.archive_file.interaction.output_path
  source_hash            = data.archive_file.interaction.output_base64sha256
  content_type           = "application/zip"
  server_side_encryption = "AES256"
  tags                   = var.common_tags

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_s3_bucket_public_access_block.code,
    aws_s3_bucket_server_side_encryption_configuration.code
  ]
}

# CloudFormation supports Python 3.14 with the repository's pinned AWS provider.
resource "aws_cloudformation_stack" "interaction" {
  name = "ServiceNow-Interaction-btsgsd-dev-lambda"
  tags = var.common_tags

  parameters = {
    ExecutionRoleArn = aws_iam_role.execution.arn
    CodeBucket       = aws_s3_object.code.bucket
    CodeKey          = aws_s3_object.code.key
    LogGroupName     = aws_cloudwatch_log_group.interaction.name
  }

  template_body = jsonencode({
    AWSTemplateFormatVersion = "2010-09-09"

    Parameters = {
      ExecutionRoleArn = { Type = "String" }
      CodeBucket       = { Type = "String" }
      CodeKey          = { Type = "String" }
      LogGroupName     = { Type = "String" }
    }

    Resources = {
      InteractionFunction = {
        Type = "AWS::Lambda::Function"

        Properties = merge({
          FunctionName     = local.function_name
          Runtime          = "python3.14"
          Architectures    = ["x86_64"]
          Handler          = "lambda_function.lambda_handler"
          PackageType      = "Zip"
          MemorySize       = 512
          Timeout          = 8
          EphemeralStorage = { Size = 512 }
          Role             = { Ref = "ExecutionRoleArn" }

          Code = {
            S3Bucket = { Ref = "CodeBucket" }
            S3Key    = { Ref = "CodeKey" }
          }

          LoggingConfig = {
            LogFormat = "Text"
            LogGroup  = { Ref = "LogGroupName" }
          }

          Environment = {
            Variables = merge({
              SN_INSTANCE = "abbvienowdev"
              SN_CTI_RULE = "cti_gsd"
            }, var.environment_variables)
          }

          Tags = [
            for key, value in var.common_tags : {
              Key   = key
              Value = value
            }
          ]
          }, var.reserved_concurrency == null ? {} : {
          ReservedConcurrentExecutions = var.reserved_concurrency
        })
      }
    }

    Outputs = {
      FunctionName = {
        Value = { Ref = "InteractionFunction" }
      }
      FunctionArn = {
        Value = { "Fn::GetAtt" = ["InteractionFunction", "Arn"] }
      }
    }
  })

  lifecycle {
    precondition {
      condition = var.reserved_concurrency == null ? true : (
        tonumber(data.external.capacity[0].result.maximum_reservation) >= var.reserved_concurrency
      )
      error_message = "Requested reserved concurrency exceeds available regional capacity. Increase the quota, release other reservations, or set reserved_concurrency to null."
    }
  }

  depends_on = [aws_iam_role_policy.logging]
}

output "deployment" {
  value = {
    function_name = aws_cloudformation_stack.interaction.outputs["FunctionName"]
    function_arn  = aws_cloudformation_stack.interaction.outputs["FunctionArn"]
    log_group     = aws_cloudwatch_log_group.interaction.name
  }
}
