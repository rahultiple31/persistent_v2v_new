# Existing role must trust lambda.amazonaws.com and include
# the telemetry permissions required by the selected ADOT layer.
data "aws_iam_role" "lambda_role" {
  name = var.iam_role_name
}

resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = var.log_group_name
  retention_in_days = 14
  tags              = var.common_tags
}

resource "aws_iam_role_policy" "lambda_logs" {
  name = "${var.function_name}-logs"
  role = data.aws_iam_role.lambda_role.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ]
      Resource = "${aws_cloudwatch_log_group.lambda_logs.arn}:*"
    }]
  })
}

resource "aws_lambda_function" "lambda" {
  function_name = var.function_name

  filename         = var.zip_path
  source_code_hash = filebase64sha256(var.zip_path)

  role          = data.aws_iam_role.lambda_role.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.13"
  architectures = ["x86_64"]
  package_type  = "Zip"

  memory_size = 128
  timeout     = 3

  ephemeral_storage {
    size = 512
  }

  layers = [var.layer_arn]

  environment {
    variables = var.environment_variables
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.lambda_logs.name
  }

  tags = var.common_tags

  depends_on = [aws_iam_role_policy.lambda_logs]
}

# Configure the Lex alias's Lambda code hook separately.
resource "aws_lambda_permission" "lex_invoke" {
  count = var.lex_bot_alias_arn == null ? 0 : 1

  statement_id   = "lex-lambda-invokeFunction-${split("/", var.lex_bot_alias_arn)[1]}-${split("/", var.lex_bot_alias_arn)[2]}"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.lambda.function_name
  principal      = "lexv2.amazonaws.com"
  source_arn     = var.lex_bot_alias_arn
  source_account = split(":", var.lex_bot_alias_arn)[4]

  # Unqualified function permission; do not set qualifier = "$LATEST".
}
