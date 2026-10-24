variable "create_signing_profile" {
  description = "Enable or disable signing profile creation"
  type        = bool
  default     = true
}

resource "aws_signer_signing_profile" "this" {
  count = var.create_signing_profile ? 1 : 0

  name        = "BTFSD_V2V_US"
  platform_id = "AWSLambda-SHA384-ECDSA"

  tags = {
    Environment = "v2v"
    Name        = "BTFSD_V2V_US"
  }
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