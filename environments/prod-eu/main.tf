locals {
  common_tags = merge(var.common_tags, {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
    Platform    = "Amazon Connect"
    Application = var.app_name
    Network     = "No Custom VPC"
  })
}

module "connect_eu_central_1" {
  count  = 1
  source = "../../modules-prod/connect"

  providers = {
    aws = aws.eu_central_1
  }

  project_name          = var.project_name
  environment           = var.environment
  aws_region            = "eu-central-1"
  region_code           = "eu-central-1"
  common_tags           = local.common_tags
  contact_center_alias  = var.contact_center_alias
  service_name_suffix   = var.connect_name_suffix
  admin_user_enabled    = var.connect_admin_user_enabled
  admin_user_first_name = var.connect_admin_first_name
  admin_user_last_name  = var.connect_admin_last_name
  admin_user_username   = var.connect_admin_username
  admin_user_email      = var.connect_admin_email
}
