terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.100"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  function_name = "UpdateSessionAttributes-dev"
}

data "archive_file" "code" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.root}/${local.function_name}.zip"
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

resource "aws_iam_role_policy" "execution" {
  name = "${local.function_name}-permissions"
  role = aws_iam_role.execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "${aws_cloudwatch_log_group.this.arn}:*"
      },
      {
        Effect   = "Allow"
        Action   = ["connect:DescribeContact"]
        Resource = "${var.connect_instance_arn}/contact/*"
      },
      {
        Effect = "Allow"
        Action = ["wisdom:UpdateSessionData"]
        Resource = format(
          "arn:%s:wisdom:%s:%s:session/%s/*",
          data.aws_partition.current.partition,
          data.aws_region.current.name,
          data.aws_caller_identity.current.account_id,
          var.assistant_id
        )
      },
    ]
  })
}

resource "aws_s3_bucket" "code" {
  bucket_prefix = "update-session-attributes-dev-code-"
  tags          = var.common_tags
}

resource "aws_s3_bucket_public_access_block" "code" {
  bucket = aws_s3_bucket.code.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "code" {
  bucket                 = aws_s3_bucket.code.id
  key                    = "lambda/${data.archive_file.code.output_sha256}.zip"
  source                 = data.archive_file.code.output_path
  source_hash            = data.archive_file.code.output_base64sha256
  content_type           = "application/zip"
  server_side_encryption = "AES256"

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [aws_s3_bucket_public_access_block.code]
}

# CloudFormation follows the repository's Python 3.14 deployment pattern.
# Reserved concurrency 300 requires sufficient regional Lambda capacity.
resource "aws_cloudformation_stack" "lambda" {
  name = "${local.function_name}-lambda"
  tags = var.common_tags

  template_body = jsonencode({
    AWSTemplateFormatVersion = "2010-09-09"

    Resources = {
      Function = {
        Type = "AWS::Lambda::Function"

        Properties = {
          FunctionName                 = local.function_name
          Runtime                      = "python3.14"
          Architectures                = ["x86_64"]
          Handler                      = "lambda_function.handler"
          PackageType                  = "Zip"
          Role                         = aws_iam_role.execution.arn
          MemorySize                   = 128
          Timeout                      = 8
          ReservedConcurrentExecutions = 300

          EphemeralStorage = {
            Size = 512
          }

          Code = {
            S3Bucket = aws_s3_object.code.bucket
            S3Key    = aws_s3_object.code.key
          }

          LoggingConfig = {
            LogFormat = "Text"
            LogGroup  = aws_cloudwatch_log_group.this.name
          }

          RuntimeManagementConfig = {
            UpdateRuntimeOn = "Auto"
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
        Value = { Ref = "Function" }
      }
      FunctionArn = {
        Value = { "Fn::GetAtt" = ["Function", "Arn"] }
      }
    }
  })

  depends_on = [aws_iam_role_policy.execution]
}

resource "aws_lambda_permission" "connect" {
  statement_id   = "AllowAmazonConnect"
  action         = "lambda:InvokeFunction"
  function_name  = aws_cloudformation_stack.lambda.outputs["FunctionName"]
  principal      = "connect.amazonaws.com"
  source_arn     = var.connect_instance_arn
  source_account = data.aws_caller_identity.current.account_id
}

resource "aws_connect_lambda_function_association" "this" {
  instance_id  = element(reverse(split("/", var.connect_instance_arn)), 0)
  function_arn = aws_cloudformation_stack.lambda.outputs["FunctionArn"]

  depends_on = [aws_lambda_permission.connect]
}
