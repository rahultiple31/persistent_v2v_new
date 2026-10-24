terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

variable "signing_profile_version_arn" {
  description = "AWS Signer signing profile version ARN"
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:signer:[a-z0-9-]+:[0-9]{12}:/signing-profiles/[A-Za-z0-9_]{2,64}/[A-Za-z0-9]{10}$", var.signing_profile_version_arn))
    error_message = "signing_profile_version_arn must be an AWS Signer profile version ARN, including its 10-character version suffix."
  }
}

variable "common_tags" {
  description = "Tags applied to the code signing configuration."
  type        = map(string)
  default     = {}
  nullable    = false
}

resource "aws_lambda_code_signing_config" "this" {
  description = "BTFSD-V2V-US"
  tags        = var.common_tags

  allowed_publishers {
    signing_profile_version_arns = [
      var.signing_profile_version_arn
    ]
  }

  policies {
    untrusted_artifact_on_deployment = "Warn"
  }
}

output "code_signing_config_arn" {
  value = aws_lambda_code_signing_config.this.arn
}

output "code_signing_config_id" {
  value = aws_lambda_code_signing_config.this.config_id
}
