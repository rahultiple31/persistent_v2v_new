data "archive_file" "survey" {
  type        = "zip"
  source_file = var.source_file == null ? "${path.module}/src/lambda_function.py" : var.source_file
  output_path = "${path.root}/metadata/${var.function_name}.zip"
}

module "application_signals" {
  source    = "../lambda-application-signals"
  role_name = aws_iam_role.execution["lambda"].name
}

resource "aws_lambda_function" "survey" {
  code_signing_config_arn = var.code_signing_config_arn

  layers = [module.application_signals.layer_arn]

  tracing_config {
    mode = "Active"
  }

  function_name    = var.function_name
  role             = aws_iam_role.execution["lambda"].arn
  runtime          = var.runtime
  handler          = var.handler
  architectures    = var.architectures
  memory_size      = var.memory_size
  timeout          = var.timeout
  filename         = data.archive_file.survey.output_path
  source_code_hash = data.archive_file.survey.output_base64sha256
  tags             = var.common_tags

  environment {
    variables = merge(var.environment_variables, {
      CONNECT_INSTANCE_ID = data.aws_connect_instance.selected.id
    }, module.application_signals.environment_variables)
  }

  depends_on = [
    aws_cloudwatch_log_group.survey,
    aws_iam_role_policy.lambda_access
  ]
}
