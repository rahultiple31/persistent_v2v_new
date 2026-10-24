terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws      = { source = "hashicorp/aws", version = ">= 5.100.0, < 7.0.0" }
    archive  = { source = "hashicorp/archive", version = "~> 2.0" }
    external = { source = "hashicorp/external", version = "~> 2.3" }
    time     = { source = "hashicorp/time", version = "~> 0.13" }
  }
}

variable "common_tags" {
  type    = map(string)
  default = {}
}

variable "python_executable" {
  type    = string
  default = "python3"
}

variable "reserved_concurrency" {
  description = "Positive reserved concurrency, or null to use the shared unreserved pool."
  type        = number
  default     = 200
  nullable    = true

  validation {
    condition = var.reserved_concurrency == null ? true : (
      var.reserved_concurrency >= 1 &&
      floor(var.reserved_concurrency) == var.reserved_concurrency
    )
    error_message = "reserved_concurrency must be null or a positive whole number."
  }
}

variable "environment_variables" {
  type    = map(string)
  default = {}
}

variable "secret_kms_key_arn" {
  description = "Customer-managed KMS key ARN, if used by the existing secret."
  type        = string
  default     = null
}

locals {
  function_name = "BTSGSD-V2V-US-Nextthink_Handoff"
  secret_name   = "Nextthink/Clientid/Secretkey"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Read secret metadata only; credential values remain outside Terraform state.
data "aws_secretsmanager_secret" "credentials" {
  name = local.secret_name
}

# Check capacity only when reserving executions.
data "external" "capacity" {
  count = var.reserved_concurrency == null ? 0 : 1

  program = [
    var.python_executable,
    "${path.module}/../lambda-snow-btsgsd-dev/scripts/check_capacity.py"
  ]

  query = {
    region        = data.aws_region.current.region
    account_id    = data.aws_caller_identity.current.account_id
    function_name = local.function_name
  }
}

data "archive_file" "handoff" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.root}/metadata/lambda-nextthink-handoff/${local.function_name}.zip"
}

resource "aws_cloudwatch_log_group" "handoff" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = 90
  tags              = var.common_tags
}

data "aws_iam_role" "execution" {
  name = "Nextthink_Handoff_btsgsd-dev-role"
}

# Preserve any previously managed role when switching to the existing role.
removed {
  from = aws_iam_role.execution

  lifecycle {
    destroy = false
  }
}

resource "aws_iam_role_policy" "execution" {
  name = "BTSGSD-V2V-US-nextthink-handoff-access"
  role = data.aws_iam_role.execution.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Effect   = "Allow"
          Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
          Resource = "${aws_cloudwatch_log_group.handoff.arn}:*"
        },
        {
          Effect   = "Allow"
          Action   = ["secretsmanager:GetSecretValue"]
          Resource = data.aws_secretsmanager_secret.credentials.arn
        }
      ],
      var.secret_kms_key_arn == null ? [] : [
        {
          Effect   = "Allow"
          Action   = ["kms:Decrypt"]
          Resource = var.secret_kms_key_arn
          Condition = {
            StringEquals = {
              "kms:ViaService"                  = "secretsmanager.${data.aws_region.current.region}.amazonaws.com"
              "kms:EncryptionContext:SecretARN" = data.aws_secretsmanager_secret.credentials.arn
            }
          }
        }
      ]
    )
  })
}

# The existing role must trust lambda.amazonaws.com.
# Allow time for policy propagation before creating the Lambda.
resource "time_sleep" "execution_role_propagation" {
  create_duration = "60s"

  triggers = {
    role_unique_id     = data.aws_iam_role.execution.unique_id
    trust_policy_hash  = sha256(data.aws_iam_role.execution.assume_role_policy)
    access_policy_hash = sha256(aws_iam_role_policy.execution.policy)
  }

  depends_on = [aws_iam_role_policy.execution]
}

# Upload the local ZIP directly to Lambda; no S3 deployment bucket is used.
resource "aws_lambda_function" "handoff" {
  function_name                  = local.function_name
  role                           = data.aws_iam_role.execution.arn
  runtime                        = "python3.14"
  architectures                  = ["x86_64"]
  handler                        = "lambda_function.lambda_handler"
  package_type                   = "Zip"
  filename                       = data.archive_file.handoff.output_path
  source_code_hash               = data.archive_file.handoff.output_base64sha256
  publish                        = false
  memory_size                    = 128
  timeout                        = 8
  reserved_concurrent_executions = var.reserved_concurrency == null ? -1 : var.reserved_concurrency
  tags                           = var.common_tags

  ephemeral_storage {
    size = 512
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.handoff.name
  }

  environment {
    variables = merge(var.environment_variables, {
      NEXTHINK_SECRET_NAME = local.secret_name
    })
  }
  lifecycle {
    precondition {
      condition = var.reserved_concurrency == null ? true : (
        tonumber(data.external.capacity[0].result.maximum_reservation) >= var.reserved_concurrency
      )
      error_message = "Requested reserved concurrency exceeds available regional capacity. Increase the quota, release other reservations, or set reserved_concurrency to null."
    }

    precondition {
      condition     = data.archive_file.handoff.output_size <= 50 * 1024 * 1024
      error_message = "Direct Lambda uploads require a ZIP package no larger than 50 MiB."
    }
  }

  depends_on = [time_sleep.execution_role_propagation]
}

output "deployment" {
  value = {
    function_name = aws_lambda_function.handoff.function_name
    function_arn  = aws_lambda_function.handoff.arn
    log_group     = aws_cloudwatch_log_group.handoff.name
  }
}
