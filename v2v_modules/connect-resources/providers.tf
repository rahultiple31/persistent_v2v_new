terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    # Agent statuses are not supported by hashicorp/aws; awscc (Cloud Control) is used for them.
    awscc = {
      source  = "hashicorp/awscc"
      version = "~> 1.0"
    }
  }
}
