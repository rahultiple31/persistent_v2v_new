data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

data "external" "capacity" {
  program = [var.python_executable, "${path.module}/scripts/check_capacity.py"]

  query = {
    region        = data.aws_region.current.name
    account_id    = data.aws_caller_identity.current.account_id
    function_name = var.function_name
  }
}

# Package ./src with lambda_function.py at the ZIP root.
data "archive_file" "snow" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.root}/${var.function_name}.zip"
}

resource "aws_cloudwatch_log_group" "snow" {
  name              = "/aws/lambda/${var.function_name}"
  retention_in_days = var.log_retention_days
  tags              = var.common_tags
}

resource "aws_iam_role" "execution" {
  name = "${var.function_name}-lambda-role"
  tags = var.common_tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "logging" {
  name = "snow-cloudwatch-logs"
  role = aws_iam_role.execution.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.snow.arn}:*"
    }]
  })
}

resource "aws_s3_bucket" "code" {
  bucket_prefix = "${lower(replace(var.function_name, "_", "-"))}-code-"
  tags          = var.common_tags
}

resource "aws_s3_bucket_public_access_block" "code" {
  bucket                  = aws_s3_bucket.code.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "code" {
  bucket = aws_s3_bucket.code.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_object" "code" {
  bucket                 = aws_s3_bucket.code.id
  key                    = "snow/${data.archive_file.snow.output_sha256}.zip"
  source                 = data.archive_file.snow.output_path
  source_hash            = data.archive_file.snow.output_base64sha256
  content_type           = "application/zip"
  server_side_encryption = "AES256"
  tags                   = var.common_tags

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_s3_bucket_public_access_block.code,
    aws_s3_bucket_server_side_encryption_configuration.code
  ]
}

locals {
  function_properties = merge({
    FunctionName                 = var.function_name
    Runtime                      = "python3.14"
    Architectures                = ["x86_64"]
    Handler                      = "lambda_function.lambda_handler"
    MemorySize                   = 512
    Timeout                      = 8
    EphemeralStorage             = { Size = 512 }
    PackageType                  = "Zip"
    ReservedConcurrentExecutions = 300
    SnapStart                    = { ApplyOn = "PublishedVersions" }
    RuntimeManagementConfig      = { UpdateRuntimeOn = "Auto" }
    LoggingConfig                = { LogFormat = "Text", LogGroup = { Ref = "LogGroupName" } }
    Role                         = { Ref = "ExecutionRoleArn" }
    Code                         = { S3Bucket = { Ref = "CodeBucket" }, S3Key = { Ref = "CodeKey" } }
    Tags                         = [for key, value in var.common_tags : { Key = key, Value = value }]
    }, length(var.environment_variables) == 0 ? {} : {
    Environment = { Variables = var.environment_variables }
  })

  # Changing code or function configuration creates a fresh published version.
  # SnapStart applies to published versions, rather than unqualified $LATEST.
  version_logical_id = "SNOWVersion${substr(sha256(jsonencode({
    code_hash = data.archive_file.snow.output_base64sha256
    settings  = local.function_properties
  })), 0, 16)}"

  template = {
    AWSTemplateFormatVersion = "2010-09-09"
    Parameters = {
      ExecutionRoleArn = { Type = "String" }
      CodeBucket       = { Type = "String" }
      CodeKey          = { Type = "String" }
      CodeHash         = { Type = "String" }
      LogGroupName     = { Type = "String" }
    }
    Resources = {
      SNOWFunction = {
        Type       = "AWS::Lambda::Function"
        Properties = local.function_properties
      }
      (local.version_logical_id) = {
        Type = "AWS::Lambda::Version"
        Properties = {
          FunctionName = { Ref = "SNOWFunction" }
          CodeSha256   = { Ref = "CodeHash" }
        }
      }
    }
    Outputs = {
      FunctionName = { Value = { Ref = "SNOWFunction" } }
      FunctionArn  = { Value = { "Fn::GetAtt" = ["SNOWFunction", "Arn"] } }
      VersionArn   = { Value = { Ref = local.version_logical_id } }
      Version      = { Value = { "Fn::GetAtt" = [local.version_logical_id, "Version"] } }
    }
  }
}

# AWS provider 5.100 validates runtimes only through Python 3.13. CloudFormation
# supports Python 3.14 without upgrading the provider used by existing modules.
resource "aws_cloudformation_stack" "snow" {
  name          = "${replace(var.function_name, "_", "-")}-lambda"
  template_body = jsonencode(local.template)
  tags          = var.common_tags

  parameters = {
    ExecutionRoleArn = aws_iam_role.execution.arn
    CodeBucket       = aws_s3_object.code.bucket
    CodeKey          = aws_s3_object.code.key
    CodeHash         = data.archive_file.snow.output_base64sha256
    LogGroupName     = aws_cloudwatch_log_group.snow.name
  }

  lifecycle {
    precondition {
      condition     = tonumber(data.external.capacity.result.maximum_reservation) >= 300
      error_message = "SNOW_btsgsd-dev requires reserved concurrency 300, but the available reservation is ${data.external.capacity.result.maximum_reservation}. AWS requires at least 100 unreserved executions; increase the regional concurrency quota or release other reservations before applying. Current unreserved: ${data.external.capacity.result.unreserved}; this function's current reservation: ${data.external.capacity.result.current_reservation}."
    }
  }

  depends_on = [aws_iam_role_policy.logging]
}
