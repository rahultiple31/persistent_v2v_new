################################################################################
# SSM Module
# Creates:
#   • /V2V/POC/forceBackupTranslation  — "false" by default; change by hand to
#     switch every V2V call to the Transcribe+Translate+Polly backup path.
#   • /V2V/POC/bedrockRegion           — records the AI region at deploy time.
#   • /V2V/POC/promptVersions          — the approved interpreter prompt
#     version of each language, "{}" (built-in prompts) at first; changed by
#     hand to approve or roll back a prompt.
#
# NOTE: The test sign-in password is not in Parameter Store: it is a Secrets
# Manager secret created by hand (see environments/v2v-resources-dev/README.md).
#
# NOTE: The interpreter prompts themselves (/V2V/POC/prompts/<language>,
# SecureString) are NOT created here. They are made once by hand
# (proxy_backend/scripts/export-prompts.js) and then edited in the console, so
# a deploy can never overwrite an edited prompt, and the prompt text is never
# in Terraform state. Terraform only grants the proxy read access to them.
#
# Mirrors CDK: PrivatePocStack > Service > forceBackupParameter + BedrockRegionParameter
#              + PromptVersionsParameter
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

resource "aws_ssm_parameter" "prompt_versions" {
  name        = "${var.ssm_hierarchy}promptVersions"
  type        = "String"
  value       = "{}"
  description = "Approved V2V interpreter prompt versions, e.g. {\"en\":1,\"es\":2}; a language left out uses the built-in prompt"

  # Terraform only writes this value on first creation. Approving a prompt
  # version (or rolling back) is a change in the AWS console or via AWS CLI —
  # the proxy polls it every 30 seconds without a redeployment.
  lifecycle {
    ignore_changes = [value]
  }

  tags = {
    Name = "${var.stack_name}-prompt-versions"
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
