terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.100.0, < 7.0.0"
    }
  }
}

variable "profile" {
  type = string

  validation {
    condition     = contains(["customer-number", "prompt"], var.profile)
    error_message = "profile must be customer-number or prompt."
  }
}

variable "connect_instance_arn" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "template_bucket" {
  type = object({
    name                 = string
    regional_domain_name = string
  })
  default = null
}
