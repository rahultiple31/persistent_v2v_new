terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.100.0, < 7.0.0"
    }
  }
}

locals {
  # Only secret names are exposed for resource addressing.
  secret_names = nonsensitive(toset(keys(var.secrets)))
}

resource "aws_secretsmanager_secret" "this" {
  for_each = local.secret_names

  name                    = "BTSGSD-V2V-US-${replace(replace(each.key, "/(?i)^(btsgsd-v2v-us-|btsgsd-dev-us-east-1-|btsgsd-dev-|btsgsd-sso-(us-)?|btsgsd-)/", ""), "/(?i)([-_]btsgsd-dev|[-_]dev)$/", "")}"
  recovery_window_in_days = 30
  tags                    = var.common_tags
}

resource "aws_secretsmanager_secret_version" "this" {
  for_each = local.secret_names

  secret_id     = aws_secretsmanager_secret.this[each.key].id
  secret_string = jsonencode(var.secrets[each.key])
}
