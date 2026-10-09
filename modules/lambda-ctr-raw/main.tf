# Package the metadata source using the module name expected by the Python handler.
data "archive_file" "raw" {
  type                    = "zip"
  source_content          = file(var.source_file)
  source_content_filename = "${split(".", var.handler)[0]}.py"
  output_path             = "${path.root}/${var.function_name}.zip"
}

resource "aws_lambda_function" "raw" {
  function_name    = var.function_name
  role             = aws_iam_role.execution.arn
  runtime          = var.runtime
  handler          = var.handler
  architectures    = var.architectures
  memory_size      = var.memory_size
  timeout          = var.timeout
  package_type     = "Zip"
  filename         = data.archive_file.raw.output_path
  source_code_hash = data.archive_file.raw.output_base64sha256
  tags             = var.common_tags

  ephemeral_storage {
    size = var.ephemeral_storage_size
  }

  environment {
    variables = var.environment_variables
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.raw.name
  }

  depends_on = [
    aws_cloudwatch_log_group.raw,
    aws_iam_role_policy.lambda_access
  ]
}
