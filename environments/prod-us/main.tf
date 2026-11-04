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

module "connect_us_east_1" {
  count  = 1
  source = "../../modules-prod/connect"

  providers = {
    aws = aws.us_east_1
  }

  project_name          = var.project_name
  environment           = var.environment
  aws_region            = "us-east-1"
  region_code           = "us-east-1"
  common_tags           = local.common_tags
  contact_center_alias  = var.contact_center_alias
  service_name_suffix   = var.connect_name_suffix
  admin_user_enabled    = var.connect_admin_user_enabled
  admin_user_first_name = var.connect_admin_first_name
  admin_user_last_name  = var.connect_admin_last_name
  admin_user_username   = var.connect_admin_username
  admin_user_email      = var.connect_admin_email

  customer_queue_flow_content = file(
    "${path.module}/metadata/contact-flows/abbvie-us-sd-transfer-to-agent-customer-queue-flow.json"
  )

  outbound_whisper_flow_content = file(
    "${path.module}/metadata/contact-flows/abbvie-us-sd-outbound-whisper-flow.json"
  )

  agent_transfer_flow_content = file(
    "${path.module}/metadata/contact-flows/abbvie-us-sd-agent-to-agent-transfer-flow.json"
  )
}
