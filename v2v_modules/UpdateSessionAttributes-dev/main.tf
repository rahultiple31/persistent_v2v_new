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
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  function_name = var.function_name
}

# Build the current handler instead of relying on a prebuilt ZIP in checkout.
data "archive_file" "code" {
  count = var.source_file != null ? 1 : 0

  type        = "zip"
  output_path = var.zip_path

  source {
    content  = file(var.source_file)
    filename = "lambda_function.py"
  }

  source {
    content  = file("${path.module}/warmup_wrapper.py")
    filename = "warmup_wrapper.py"
  }
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = 14
  tags              = var.common_tags
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

resource "aws_iam_role_policy_attachment" "lambda_vpc_access" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy_attachment" "xray" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AWSXRayDaemonWriteAccess"
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
          data.aws_region.current.region,
          data.aws_caller_identity.current.account_id,
          var.assistant_id
        )
      },
    ]
  })
}

# Allow IAM propagation before the first function creation.
resource "time_sleep" "execution_role_ready" {
  create_duration = "60s"

  triggers = {
    role_id = aws_iam_role.execution.unique_id
  }

  depends_on = [
    aws_iam_role_policy.execution,
    aws_iam_role_policy_attachment.xray,
    aws_iam_role_policy_attachment.lambda_vpc_access,
  ]
}

module "application_signals" {
  source             = "../lambda-application-signals"
  role_name          = aws_iam_role.execution.name
  attach_xray_policy = false
}

# Deploy the core security group before planning these Lambda settings.
data "aws_security_group" "lambda_core" {
  name   = "BTSGSD-V2V-US-LAMBDA-core-sg"
  vpc_id = "vpc-0f2abb3d6596a0487"
}

resource "aws_lambda_function" "this" {
  code_signing_config_arn = var.code_signing_config_arn

  layers = [module.application_signals.layer_arn]

  function_name                  = local.function_name
  role                           = aws_iam_role.execution.arn
  runtime                        = "python3.13"
  architectures                  = ["x86_64"]
  handler                        = "warmup_wrapper.handler"
  package_type                   = "Zip"
  filename                       = var.source_file != null ? data.archive_file.code[0].output_path : var.zip_path
  source_code_hash               = var.source_file != null ? data.archive_file.code[0].output_base64sha256 : filebase64sha256(var.zip_path)
  memory_size                    = 128
  timeout                        = 8
  reserved_concurrent_executions = -1

  ephemeral_storage {
    size = 512
  }

  vpc_config {
    # VPC: vpc-0f2abb3d6596a0487 (abv-vpc-accas-dev-vpc).
    # Lambda derives the VPC from these subnet IDs.
    subnet_ids = [
      "subnet-0c29b5f2c41c73d89", # us-east-1a: abv-vpc-accas-dev-app-a
      "subnet-0fe7a72e5cef073ad", # us-east-1b: abv-vpc-accas-dev-app-b
    ]

    security_group_ids = [
      "sg-0e77977e08fb0dedb", # BTSGSD-US-IVA-Internal-SG
      data.aws_security_group.lambda_core.id,
    ]

    ipv6_allowed_for_dual_stack = false
  }

  tracing_config {
    mode = "Active"
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.this.name
  }

  environment {
    variables = merge({
      NAMESPACE        = "Custom"
      LOG_LEVEL        = "INFO"
      API_TIMEOUT      = "1.5"
      API_MAX_ATTEMPTS = "2"
      ORIGINAL_HANDLER = "lambda_function.handler"
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
