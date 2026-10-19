# Existing role must trust lambda.amazonaws.com.
data "aws_iam_role" "lambda_role" {
  name = var.iam_role_name
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

resource "aws_lambda_function" "lambda" {
  function_name = var.function_name

  filename         = var.zip_path
  source_code_hash = filebase64sha256(var.zip_path)

  role          = data.aws_iam_role.lambda_role.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.14"
  architectures = ["x86_64"]
  package_type  = "Zip"

  memory_size = 128
  timeout     = 7

  ephemeral_storage {
    size = 512
  }

  environment {
    variables = var.environment_variables
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.lambda_logs.name
  }

  tags = var.common_tags

  depends_on = [aws_iam_role_policy.lambda_access]
}
