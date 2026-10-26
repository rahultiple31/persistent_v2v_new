################################################################################
# Terraform & Provider Configuration
################################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    # null provider is required by modules/dns for the Connect approved-origin
    # local-exec provisioner (aws_connect_approved_origin does not exist in
    # the hashicorp/aws provider; the AWS CLI call is the correct substitute).
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.tags
  }
}



terraform {
  backend "s3" {
    bucket  = "bts-cloud-terraform-tfstate"
    key     = "terraform-state/V2V-poc/terraform.tfstate"
    region  = "us-east-1"
    encrypt = true
  }
}