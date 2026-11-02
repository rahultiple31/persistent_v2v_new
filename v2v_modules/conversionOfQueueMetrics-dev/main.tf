# Existing role must trust lambda.amazonaws.com.
data "aws_iam_role" "lambda_role" {
  name = var.iam_role_name
}

resource "aws_iam_role_policy_attachment" "lambda_vpc_access" {
  role       = data.aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_dynamodb_table" "queue_info" {
  name = var.environment_variables["TableName"]
}

resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = var.log_group_name
  retention_in_days = 14
  tags              = var.common_tags
}

resource "aws_iam_role_policy" "lambda_access" {
  name = "${var.function_name}-permissions"
  role = data.aws_iam_role.lambda_role.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:UpdateItem"
        ]
        Resource = data.aws_dynamodb_table.queue_info.arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.lambda_logs.arn}:*"
      }
    ]
  })
}

module "application_signals" {
  source    = "../lambda-application-signals"
  role_name = data.aws_iam_role.lambda_role.name
}

# Deploy the core security group before planning these Lambda settings.
data "aws_security_group" "lambda_core" {
  name   = "BTSGSD-V2V-US-LAMBDA-core-sg"
  vpc_id = "vpc-0f2abb3d6596a0487"
}

resource "aws_lambda_function" "lambda" {
  code_signing_config_arn = var.code_signing_config_arn

  layers = [module.application_signals.layer_arn]

  tracing_config {
    mode = "Active"
  }

  function_name = var.function_name

  filename         = var.zip_path
  source_code_hash = filebase64sha256(var.zip_path)

  role          = data.aws_iam_role.lambda_role.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.13"
  architectures = ["x86_64"]
  package_type  = "Zip"

  memory_size = 128
  timeout     = 7

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

  environment {
    variables = {
      for key, value in merge(
        var.environment_variables,
        module.application_signals.environment_variables,
      ) : key => value
      if !contains([
        "AWS_LAMBDA_EXEC_WRAPPER",
        "OTEL_AWS_APPLICATION_SIGNALS_ENABLED",
      ], key)
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.lambda_logs.name
  }

  tags = var.common_tags

  depends_on = [
    aws_iam_role_policy.lambda_access,
    aws_iam_role_policy_attachment.lambda_vpc_access,
  ]
}
