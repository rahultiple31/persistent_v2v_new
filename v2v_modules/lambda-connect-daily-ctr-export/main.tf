# Package the source using the module name expected by the Python handler.
data "archive_file" "export" {
  type                    = "zip"
  source_content          = file(var.source_file == null ? "${path.module}/src/lambda_function_ctr_export.py" : var.source_file)
  source_content_filename = "${split(".", var.handler)[0]}.py"
  output_path             = "${path.root}/metadata/lambda-connect-daily-ctr-export/${var.function_name}.zip"
}

module "application_signals" {
  source    = "../lambda-application-signals"
  role_name = aws_iam_role.execution["lambda"].name
}

resource "aws_lambda_function" "export" {
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
  package_type     = "Zip"
  filename         = data.archive_file.export.output_path
  source_code_hash = data.archive_file.export.output_base64sha256
  tags             = local.effective_tags

  ephemeral_storage {
    size = var.ephemeral_storage_size
  }

  environment {
    variables = merge(var.environment_variables, {
      CONNECT_INSTANCE_ID = data.aws_connect_instance.selected.id
      S3_BUCKET           = var.s3_bucket_name
      S3_PREFIX           = local.s3_prefix_by_area[var.deployment_area]
      S3_REGION           = data.aws_region.current.name
    }, module.application_signals.environment_variables)
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.export.name
  }

  depends_on = [
    aws_cloudwatch_log_group.export,
    aws_iam_role_policy.lambda_access
  ]
}
