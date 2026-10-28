terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.100.0, < 7.0.0"
    }
  }
}

resource "aws_secretsmanager_secret" "this" {
  name                    = "BTSGSD-V2V-US-Datalake/dev"
  recovery_window_in_days = 30
}
