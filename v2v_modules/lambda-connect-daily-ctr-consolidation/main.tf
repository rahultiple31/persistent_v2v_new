locals {
  function_name  = "BTSGSD-V2V-US-connect-daily-ctr-consolidation"
  scheduler_name = "BTSGSD-V2V-US-east-1-ACD-Daily-Consolidation"
  bucket_name    = "btsgsd-v2v-us-connect-reporting-bucket"
}

data "aws_partition" "current" {}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

data "archive_file" "lambda" {
  type             = "zip"
  source_file      = "${path.module}/src/lambda_function.py"
  output_file_mode = "0644"
  output_path      = "${path.module}/lambda_function.zip"
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = 90
}

resource "aws_iam_role" "lambda" {
  name = "${local.function_name}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "lambda" {
  name = "${local.function_name}-access"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "WriteLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.lambda.arn}:*"
      },
      {
        Sid      = "ListSourceFiles"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:${data.aws_partition.current.partition}:s3:::${local.bucket_name}"
        Condition = {
          StringLike = {
            "s3:prefix" = ["daily/acd/*", "daily/survey/*"]
          }
        }
      },
      {
        Sid    = "ReadSourceFiles"
        Effect = "Allow"
        Action = ["s3:GetObject"]
        Resource = [
          "arn:${data.aws_partition.current.partition}:s3:::${local.bucket_name}/daily/acd/*",
          "arn:${data.aws_partition.current.partition}:s3:::${local.bucket_name}/daily/survey/*"
        ]
      },
      {
        Sid      = "WriteConsolidatedFiles"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:AbortMultipartUpload"]
        Resource = "arn:${data.aws_partition.current.partition}:s3:::${local.bucket_name}/consolidated/*"
      },
      {
        Sid      = "UseS3KmsKey"
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = "arn:${data.aws_partition.current.partition}:kms:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:key/*"
        Condition = {
          StringEquals = {
            "kms:ViaService"    = "s3.${data.aws_region.current.name}.amazonaws.com"
            "kms:CallerAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

resource "aws_lambda_function" "consolidation" {
  function_name           = local.function_name
  role                    = aws_iam_role.lambda.arn
  runtime                 = "python3.14"
  handler                 = "lambda_function.lambda_handler"
  architectures           = ["arm64"]
  memory_size             = 2048
  timeout                 = 900
  package_type            = "Zip"
  filename                = data.archive_file.lambda.output_path
  source_code_hash        = data.archive_file.lambda.output_base64sha256
  code_signing_config_arn = var.code_signing_config_arn

  ephemeral_storage {
    size = 4096
  }

  environment {
    variables = {
      ACD_SOURCE_PREFIX       = "daily/acd/"
      ADD_SOURCE_COLUMNS      = "FALSE"
      BUSINESS_TIMEZONE       = "America/Chicago"
      CSV_ENCODING            = "utf-8-sig"
      EXPECTED_REGIONS        = "NORAM,EMEA,JAPAC"
      FAIL_IF_REGION_MISSING  = "FALSE"
      OUTPUT_PREFIX           = "consolidated/"
      REPORT_BUCKET           = local.bucket_name
      REPORT_DATE_OFFSET_DAYS = "1"
      S3_REGION               = "us-east-1"
      SURVEY_SOURCE_PREFIX    = "daily/survey/"
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_iam_role_policy.lambda
  ]
}

resource "aws_iam_role" "scheduler" {
  name = "${local.function_name}-scheduler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "scheduler.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "scheduler" {
  name = "${local.function_name}-invoke"
  role = aws_iam_role.scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.consolidation.arn
    }]
  })
}

resource "aws_scheduler_schedule" "consolidation" {
  name                         = local.scheduler_name
  schedule_expression          = "cron(0 2 * * ? *)"
  schedule_expression_timezone = "America/Chicago"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.consolidation.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({})
  }

  depends_on = [aws_iam_role_policy.scheduler]
}
