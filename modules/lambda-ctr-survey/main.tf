data "archive_file" "survey" {
  type        = "zip"
  source_file = var.source_file == null ? "${path.module}/src/lambda_function.py" : var.source_file
  output_path = "${path.root}/${var.function_name}.zip"
}

resource "aws_lambda_function" "survey" {
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
    })
  }

  depends_on = [
    aws_cloudwatch_log_group.survey,
    aws_iam_role_policy.lambda_access
  ]
}
