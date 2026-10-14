terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws      = { source = "hashicorp/aws", version = "~> 5.100" }
    archive  = { source = "hashicorp/archive", version = "~> 2.0" }
    external = { source = "hashicorp/external", version = "~> 2.3" }
  }
}

variable "common_tags" {
  type    = map(string)
  default = {}
}

variable "python_executable" {
  type    = string
  default = "python3"
}

variable "environment_variables" {
  type    = map(string)
  default = {}
}

variable "secret_kms_key_arn" {
  description = "Customer-managed KMS key ARN, if used by the existing secret."
  type        = string
  default     = null
}

locals {
  function_name = "Nextthink_Handoff_btsgsd-dev"
  secret_name   = "Nextthink/Clientid/Secretkey"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Read secret metadata only; credential values remain outside Terraform state.
data "aws_secretsmanager_secret" "credentials" {
  name = local.secret_name
}

# Reuse the existing read-only concurrency checker.
data "external" "capacity" {
  program = [
    var.python_executable,
    "${path.module}/../lambda-snow-btsgsd-dev/scripts/check_capacity.py"
  ]

  query = {
    region        = data.aws_region.current.name
    account_id    = data.aws_caller_identity.current.account_id
    function_name = local.function_name
  }
}

data "archive_file" "handoff" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.root}/${local.function_name}.zip"
}

resource "aws_cloudwatch_log_group" "handoff" {
  name              = "/aws/lambda/Nextthink_Handoff"
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

resource "aws_iam_role_policy" "execution" {
  name = "nextthink-handoff-access"
  role = aws_iam_role.execution.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Effect   = "Allow"
          Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
          Resource = "${aws_cloudwatch_log_group.handoff.arn}:*"
        },
        {
          Effect   = "Allow"
          Action   = ["secretsmanager:GetSecretValue"]
          Resource = data.aws_secretsmanager_secret.credentials.arn
        }
      ],
      var.secret_kms_key_arn == null ? [] : [
        {
          Effect   = "Allow"
          Action   = ["kms:Decrypt"]
          Resource = var.secret_kms_key_arn
          Condition = {
            StringEquals = {
              "kms:ViaService"                  = "secretsmanager.${data.aws_region.current.name}.amazonaws.com"
              "kms:EncryptionContext:SecretARN" = data.aws_secretsmanager_secret.credentials.arn
            }
          }
        }
      ]
    )
  })
}

resource "aws_s3_bucket" "code" {
  bucket_prefix = "nextthink-handoff-dev-code-"
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
  key                    = "handoff/${data.archive_file.handoff.output_sha256}.zip"
  source                 = data.archive_file.handoff.output_path
  source_hash            = data.archive_file.handoff.output_base64sha256
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

# CloudFormation supports Python 3.14 with the pinned AWS provider.
resource "aws_cloudformation_stack" "handoff" {
  name = "Nextthink-Handoff-btsgsd-dev-lambda"
  tags = var.common_tags

  parameters = {
    ExecutionRoleArn = aws_iam_role.execution.arn
    CodeBucket       = aws_s3_object.code.bucket
    CodeKey          = aws_s3_object.code.key
    LogGroupName     = aws_cloudwatch_log_group.handoff.name
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
      HandoffFunction = {
        Type = "AWS::Lambda::Function"
        Properties = {
          FunctionName                 = local.function_name
          Runtime                      = "python3.14"
          Handler                      = "lambda_function.lambda_handler"
          Architectures                = ["x86_64"]
          PackageType                  = "Zip"
          MemorySize                   = 128
          Timeout                      = 8
          ReservedConcurrentExecutions = 200
          Role                         = { Ref = "ExecutionRoleArn" }

          Code = {
            S3Bucket = { Ref = "CodeBucket" }
            S3Key    = { Ref = "CodeKey" }
          }

          LoggingConfig = {
            LogFormat = "Text"
            LogGroup  = { Ref = "LogGroupName" }
          }

          Environment = {
            Variables = merge(var.environment_variables, {
              NEXTHINK_SECRET_NAME = local.secret_name
            })
          }

          Tags = [
            for key, value in var.common_tags : {
              Key   = key
              Value = value
            }
          ]
        }
      }
    }

    Outputs = {
      FunctionName = {
        Value = { Ref = "HandoffFunction" }
      }
      FunctionArn = {
        Value = { "Fn::GetAtt" = ["HandoffFunction", "Arn"] }
      }
    }
  })

  lifecycle {
    precondition {
      condition     = tonumber(data.external.capacity.result.maximum_reservation) >= 200
      error_message = "Nextthink_Handoff_btsgsd-dev requires reserved concurrency 200. Available reservation: ${data.external.capacity.result.maximum_reservation}. Increase the regional quota or release other reservations before deployment."
    }
  }

  depends_on = [aws_iam_role_policy.execution]
}

output "deployment" {
  value = {
    function_name = aws_cloudformation_stack.handoff.outputs["FunctionName"]
    function_arn  = aws_cloudformation_stack.handoff.outputs["FunctionArn"]
    log_group     = aws_cloudwatch_log_group.handoff.name
  }
}
