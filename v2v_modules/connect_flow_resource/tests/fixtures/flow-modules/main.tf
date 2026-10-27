terraform {
  required_providers {
    aws      = { source = "hashicorp/aws" }
    external = { source = "hashicorp/external" }
  }
}

locals {
  settings = {
    instance_arn                  = module.connect.instance_arn
    expected_instance_arn         = "arn:aws:connect:us-east-1:518902362956:instance/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    tags                          = { Service = "original", RegionCode = "us-east-1", AWSRegion = "us-east-1" }
    survey_data_table_id          = "test-table"
    queue_metrics_lambda_arn      = "arn:aws:lambda:us-east-1:518902362956:function:test-metrics"
    session_attributes_lambda_arn = "arn:aws:lambda:us-east-1:518902362956:function:test-session"
    timestamper_lambda_arn        = "arn:aws:lambda:us-east-1:518902362956:function:test-timestamper"
  }
}

module "connect" {
  source                      = "../../../../connect"
  project_name                = "BTSGSD"
  environment                 = "v2v"
  aws_region                  = "us-east-1"
  region_code                 = "us-east-1"
  common_tags                 = {}
  contact_center_alias        = "test"
  instance_alias              = "test"
  customer_queue_flow_content = jsonencode({ StartAction = "test", Actions = [{ Type = "DisconnectParticipant" }] })
  external_imported_contact_flows = {
    agent_transfer   = { id = module.agent_to_agent_transfer_flow.flow_id, arn = module.agent_to_agent_transfer_flow.flow_arn }
    outbound_whisper = { id = module.outbound_whisper_flow.flow_id, arn = module.outbound_whisper_flow.flow_arn }
    customer_queue   = { id = module.customer_queue_flow.flow_id, arn = module.customer_queue_flow.flow_arn }
  }
}

module "aiagent_survey_flow" {
  source   = "../../../../aiagent_survey_flow"
  settings = local.settings
}

module "agent_to_agent_transfer_flow" {
  source   = "../../../../agent_to_agent_transfer_flow"
  settings = merge(local.settings, { transfer_customer_queue_flow_arn = module.connect.managed_transfer_customer_queue_flow_arn })
}

module "outbound_whisper_flow" {
  source   = "../../../../outbound_whisper_flow"
  settings = local.settings
}

module "customer_queue_flow" {
  source   = "../../../../customer_queue_flow"
  settings = local.settings
}

module "abbvie_views" {
  source                    = "../../../../abbvie_views"
  connect_instance_arn      = module.connect.instance_arn
  customer_details_view_arn = "arn:aws:connect:us-east-1:518902362956:instance/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/view/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb:$LATEST"
  common_tags               = {}
}

output "flow_names" {
  value = [module.aiagent_survey_flow.flow_name, module.agent_to_agent_transfer_flow.flow_name, module.outbound_whisper_flow.flow_name, module.customer_queue_flow.flow_name, module.abbvie_views.flow_name]
}
output "imported_ids" { value = module.connect.imported_contact_flow_ids }
output "customer_queue_arn" { value = module.connect.customer_queue_flow_arn }
output "extracted_customer_queue_arn" { value = module.customer_queue_flow.flow_arn }
