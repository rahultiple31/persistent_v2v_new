terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

# Every optional input defaults to null, which leaves the argument unset exactly
# as before: existing callers that pass only log_group_name see no change.
resource "aws_cloudwatch_log_group" "this" {
  name              = var.log_group_name
  retention_in_days = var.retention_in_days
  kms_key_id        = var.kms_key_id
  log_group_class   = var.log_group_class
  tags              = var.tags
}
