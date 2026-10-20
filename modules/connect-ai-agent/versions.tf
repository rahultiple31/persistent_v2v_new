terraform {
  required_version = ">= 1.10.0"

  required_providers {
    awscc = {
      source  = "hashicorp/awscc"
      version = "~> 1.98.0"
    }

    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.100.0, < 7.0.0"
    }
  }
}
