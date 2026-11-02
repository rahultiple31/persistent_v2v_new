data "archive_file" "survey" {
  type        = "zip"
  source_file = var.source_file == null ? "${path.module}/src/lambda_function_ctr_.py" : var.source_file
  output_path = "${path.root}/metadata/${var.function_name}.zip"
}

module "application_signals" {
  source    = "../lambda-application-signals"
  role_name = aws_iam_role.execution["lambda"].name
}

# Deploy the core security group before planning these Lambda settings.
data "aws_security_group" "lambda_core" {
  name   = "BTSGSD-V2V-US-LAMBDA-core-sg"
  vpc_id = "vpc-0f2abb3d6596a0487"
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
  tags             = local.effective_tags

  ephemeral_storage {
    size = var.ephemeral_storage_size
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
    variables = merge(var.environment_variables, {
      CONNECT_INSTANCE_ID = data.aws_connect_instance.selected.id
      S3_REGION           = data.aws_region.current.name
    }, module.application_signals.environment_variables)
  }

  depends_on = [
    aws_cloudwatch_log_group.survey,
    aws_iam_role_policy.lambda_access,
    aws_iam_role_policy_attachment.lambda_vpc_access,
  ]
}
