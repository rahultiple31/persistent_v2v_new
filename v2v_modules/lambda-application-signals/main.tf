terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

variable "role_name" {
  description = "Lambda execution role name."
  type        = string
}

variable "attach_xray_policy" {
  description = "False when the calling module already manages this attachment."
  type        = bool
  default     = true
}

locals {
  # AWS-published ADOT Python layer for the V2V deployment region, us-east-1.
  layer_arn = "arn:aws:lambda:us-east-1:615299751070:layer:AWSOpenTelemetryDistroPython:32"

  environment_variables = {
    AWS_LAMBDA_EXEC_WRAPPER              = "/opt/otel-instrument"
    OTEL_AWS_APPLICATION_SIGNALS_ENABLED = "true"
  }

  policies = merge(
    {
      application_signals = "arn:aws:iam::aws:policy/CloudWatchLambdaApplicationSignalsExecutionRolePolicy"
    },
    var.attach_xray_policy ? {
      xray = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
    } : {}
  )
}

resource "aws_iam_role_policy_attachment" "telemetry" {
  for_each = local.policies

  role       = var.role_name
  policy_arn = each.value
}

output "layer_arn" {
  value      = local.layer_arn
  depends_on = [aws_iam_role_policy_attachment.telemetry]
}

output "environment_variables" {
  value      = local.environment_variables
  depends_on = [aws_iam_role_policy_attachment.telemetry]
}
