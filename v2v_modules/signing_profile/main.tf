terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

variable "create_signing_profile" {
  description = "Enable or disable signing profile creation"
  type        = bool
  default     = true
  nullable    = false
}

variable "profile_name" {
  description = "Immutable AWS Signer profile name; retain the existing name for an already deployed profile."
  type        = string
  default     = "BTFSD_V2V_US"
  nullable    = false

  validation {
    condition     = can(regex("^[A-Za-z0-9_]{2,64}$", var.profile_name))
    error_message = "profile_name must contain 2-64 letters, digits, or underscores."
  }
}

variable "common_tags" {
  description = "Tags applied to the signing profile."
  type        = map(string)
  default     = {}
  nullable    = false
}

resource "aws_signer_signing_profile" "this" {
  count = var.create_signing_profile ? 1 : 0

  name        = var.profile_name
  platform_id = "AWSLambda-SHA384-ECDSA"

  tags = merge(var.common_tags, {
    Environment = "v2v"
    Name        = var.profile_name
  })
}

output "signing_profile_name" {
  value = try(aws_signer_signing_profile.this[0].name, null)
}

output "signing_profile_arn" {
  value = try(aws_signer_signing_profile.this[0].arn, null)
}

output "signing_profile_version_arn" {
  value = try(aws_signer_signing_profile.this[0].version_arn, null)
}
