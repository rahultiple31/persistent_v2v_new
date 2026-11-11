# Terraform-managed copy of the manually created BTSGSD-Abbvie-views-Dev Lambda.
# It polls Amazon Connect (DescribeContact) so a contact flow can wait until a
# contact is connected to an agent or has ended. The code in src/ is the
# deployed code, unchanged.
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
  connect_instance_id = element(reverse(split("/", var.connect_instance_arn)), 0)
}

# The ZIP lands in the root module's metadata directory so the pipeline saves
# it between the Plan and Apply stages with the other Lambda packages.
data "archive_file" "code" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.root}/metadata/${var.function_name}.zip"
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/lambda/${var.function_name}"
  retention_in_days = var.log_retention_days
  tags              = var.common_tags
}

resource "aws_iam_role" "execution" {
  name = "${var.function_name}-role"

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

# Same permissions as the deployed role: log writes plus DescribeContact on the
# Connect instance. Nothing else is granted.
resource "aws_iam_role_policy" "execution" {
  name = "${var.function_name}-permissions"
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
        Resource = [var.connect_instance_arn, "${var.connect_instance_arn}/*"]
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
    aws_iam_role_policy_attachment.lambda_vpc_access,
  ]
}

module "application_signals" {
  source    = "../lambda-application-signals"
  role_name = aws_iam_role.execution.name
}

# Deploy the core security group (lambda_security_groups choice) before planning.
data "aws_security_group" "lambda_core" {
  name   = var.core_security_group_name
  vpc_id = var.vpc_id
}

resource "aws_lambda_function" "this" {
  code_signing_config_arn = var.code_signing_config_arn
  layers                  = [module.application_signals.layer_arn]

  tracing_config {
    mode = "Active"
  }

  function_name                  = var.function_name
  role                           = aws_iam_role.execution.arn
  runtime                        = "python3.13"
  architectures                  = ["x86_64"]
  handler                        = "warmup_wrapper.handler"
  package_type                   = "Zip"
  filename                       = data.archive_file.code.output_path
  source_code_hash               = data.archive_file.code.output_base64sha256
  memory_size                    = var.memory_size
  timeout                        = var.timeout
  reserved_concurrent_executions = -1

  ephemeral_storage {
    size = 512
  }

  vpc_config {
    subnet_ids                  = var.subnet_ids
    security_group_ids          = concat(var.security_group_ids, [data.aws_security_group.lambda_core.id])
    ipv6_allowed_for_dual_stack = false
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.this.name
  }

  environment {
    variables = merge(
      {
        CONNECT_INSTANCE_ID = local.connect_instance_id
        POLL_SLEEP          = tostring(var.poll_sleep_seconds)
      },
      module.application_signals.environment_variables,
      {
        ORIGINAL_HANDLER = "lambda_function.lambda_handler"
      }
    )
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
  instance_id  = local.connect_instance_id
  function_arn = aws_lambda_function.this.arn

  depends_on = [aws_lambda_permission.connect]
}
