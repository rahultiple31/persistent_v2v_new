################################################################################
# SSM Module
# Creates:
#   • /V2V/POC/forceBackupTranslation  — "false" by default; change by hand to
#     switch every V2V call to the Transcribe+Translate+Polly backup path.
#   • /V2V/POC/bedrockRegion           — records the AI region at deploy time.
#
# NOTE: The testSignIn SecureString parameter is created BY HAND (CloudFormation
# and Terraform cannot create SSM SecureString parameters without a KMS key
# resource). See PRIVATE-POC.md for instructions.
#
# Mirrors CDK: PrivatePocStack > Service > forceBackupParameter + BedrockRegionParameter
################################################################################

resource "aws_ssm_parameter" "force_backup_translation" {
  name        = "${var.ssm_hierarchy}forceBackupTranslation"
  type        = "String"
  value       = "false"
  description = "true = every V2V call uses Transcribe + Translate + Polly instead of Nova Sonic"

  # Terraform only writes this value on first creation. To toggle the backup
  # path at runtime, change the value in the AWS console or via AWS CLI —
  # the proxy polls it every 30 seconds without a redeployment.
  lifecycle {
    ignore_changes = [value]
  }

  tags = {
    Name = "${var.stack_name}-force-backup-translation"
  }
}

resource "aws_ssm_parameter" "bedrock_region" {
  name        = "${var.ssm_hierarchy}bedrockRegion"
  type        = "String"
  value       = var.ai_region
  description = "Region the V2V proxy calls Nova Sonic, Transcribe, Translate and Polly in"

  tags = {
    Name = "${var.stack_name}-bedrock-region"
  }
}
