output "main_inbound_flow_arn" {
  value = try(module.btsgsd-Main-IB-Flow[0].flow_arn, null)
}

output "queue_info_table_name" {
  value = try(module.queue_info_dynamodb[0].table_name, null)
}

output "queue_info_table_arn" {
  value = try(module.queue_info_dynamodb[0].table_arn, null)
}

output "queue_info_table_id" {
  value = try(module.queue_info_dynamodb[0].table_id, null)
}

output "dev_ai_domain" {
  description = "Dev AI domain name, assistant identifiers and associated Connect instance ARN, or null when domain creation is disabled."
  value       = try(aws_cloudformation_stack.dev_ai_domain[0].outputs, null)
}

output "dev_ai_agent" {
  description = "Published Dev AI agent and prompt identifiers, or null when AI deployment is disabled."
  value       = try(aws_cloudformation_stack.dev_ai_agent[0].outputs, null)
}

output "btsgsd_support_agent" {
  description = "Published btsgsd-SupportAgent prompt, agent and version identifiers after Admin-profile assignment."
  value       = try(module.btsgsd_support_agent[0].deployment, null)
  depends_on  = [terraform_data.dev_ai_admin_security_profiles]
}

output "btsgsd_ai_survey_agent" {
  description = "Published survey prompt and agent identifiers, including the versioned ARN for a voice flow."
  value       = try(module.btsgsd_ai_survey_agent[0].deployment, null)
}

output "sso_survey_ai_agent_id" {
  value = try(module.connect_ai_agent[0].ai_agent_id, null)
}

output "sso_survey_ai_agent_arn" {
  value = try(module.connect_ai_agent[0].ai_agent_arn, null)
}

output "sso_survey_ai_agent_version_arn" {
  value = try(module.connect_ai_agent[0].ai_agent_version_arn, null)
}

output "dev_ai_admin_security_profile" {
  description = "Existing Admin profile assigned to custom AI agents during apply, or null when disabled."
  value = local.dev_ai_admin_security_profile_enabled ? {
    name                = "Admin"
    security_profile_id = data.aws_connect_security_profile.ai_admin[0].security_profile_id
    assignment_config   = terraform_data.dev_ai_admin_security_profiles[0].output.config
  } : null
}

output "regional_connect_instances" {
  description = "Amazon Connect deployment outputs by region."
  value = {
    "us-east-1" = {
      region             = "us-east-1"
      instance_id        = try(module.connect_us_east_1[0].instance_id, null)
      instance_arn       = try(module.connect_us_east_1[0].instance_arn, null)
      queue_id           = try(module.connect_us_east_1[0].queue_id, null)
      routing_profile_id = try(module.connect_us_east_1[0].routing_profile_id, null)
      admin_user_id      = try(module.connect_us_east_1[0].admin_user_id, null)
    }
  }
}

output "regional_lambda_functions" {
  description = "Disposable Lambda test function outputs by region."
  value = {
    "us-east-1" = {
      region        = "us-east-1"
      function_name = try(module.lambda_us_east_1[0].function_name, null)
      function_arn  = try(module.lambda_us_east_1[0].function_arn, null)
      invoke_arn    = try(module.lambda_us_east_1[0].invoke_arn, null)
      role_arn      = try(module.lambda_us_east_1[0].role_arn, null)
    }
  }
}

output "snow_lambda_dev" {
  description = "BTSGSD-V2V-US-SNOW function and published-version identifiers, or null when its target is disabled."
  value       = try(module.BTSGSD-V2V-US-SNOW[0].deployment, null)
}

output "connect_v2v_translation" {
  description = "Amazon Connect V2V translation solution outputs."
  value = {
    backend_region                      = data.aws_region.current.region
    identity_pool_id                    = try(module.cognito_v2v[0].identity_pool_id, null)
    user_pool_id                        = try(module.cognito_v2v[0].user_pool_id, null)
    user_pool_web_client_id             = try(module.cognito_v2v[0].user_pool_web_client_id, null)
    cognito_domain_url                  = try(module.cognito_v2v[0].cognito_domain_url, null)
    authenticated_role_arn              = try(module.iam_v2v[0].authenticated_role_arn, null)
    unauthenticated_role_arn            = try(module.iam_v2v[0].unauthenticated_role_arn, null)
    v2v_bucket_name                     = try(module.s3_v2v[0].v2v_bucket_name, null)
    v2v_log_bucket_name                 = try(module.s3_v2v[0].v2v_log_bucket_name, null)
    cloudfront_distribution_id          = try(module.cloudfront_v2v[0].cloudfront_distribution_id, null)
    cloudfront_distribution_domain_name = try(module.cloudfront_v2v[0].cloudfront_distribution_domain_name, null)
    v2v_url                             = try(module.cloudfront_v2v[0].v2v_url, null)
    v2v_root_prefix                     = var.v2v_root_prefix
    deploy_v2v_assets                   = var.deploy_v2v_assets
    translation_mode                    = local.v2v_translation_mode
    ssm_parameter_names                 = try(module.ssm_v2v[0].parameter_names, {})
  }
}

output "servicenow_interaction_lambda" {
  description = "ServiceNow Interaction Lambda identifiers."
  value       = try(module.lambda-servicenow-interaction[0].deployment, null)
}

output "nexthink_handoff_lambda" {
  description = "Nexthink Handoff Lambda identifiers."
  value       = try(module.lambda-nextthink-handoff[0].deployment, null)
}

output "agentcore_gateway" {
  description = "BTSGSD-V2V-US-gateway-quick-start AgentCore gateway identifiers and MCP endpoint."
  value       = try(module.agentcore_gateway[0].deployment, null)
}

output "connect_views" {
  description = "Customer Details view identifiers, or null when Connect is disabled."

  value = try({
    view_id         = module.connect_views[0].view_id
    view_arn        = module.connect_views[0].view_arn
    view_latest_arn = module.connect_views[0].view_latest_arn
  }, null)
}

output "abbvie_views" {
  description = "AbbVie_Views contact flow details."

  value = try({
    id   = module.abbvie_views[0].flow_id
    arn  = module.abbvie_views[0].flow_arn
    name = module.abbvie_views[0].flow_name
  }, null)
}

output "connect_integrations" {
  description = "Dev Connect MCP integration, or null when disabled."
  value       = try(module.connect_Integrations[0].deployment, null)
}

output "secrets_manager_arns" {
  description = "Managed secret ARNs."
  value       = try(module.secrets_manager[0].secret_arns, null)
}

output "ai_agent_log_group" {
  value = try({
    name = module.cloudwatch_log_group[0].name
    arn  = module.cloudwatch_log_group[0].arn
  }, null)
}

output "lambda_name" {
  description = "UpdateSessionAttributes-dev function name, or null when Connect is disabled."
  value       = try(module.UpdateSessionAttributes-dev[0].lambda_name, null)
}

output "lambda_arn" {
  description = "UpdateSessionAttributes-dev function ARN, or null when Connect is disabled."
  value       = try(module.UpdateSessionAttributes-dev[0].lambda_arn, null)
}

output "lambda_role_arn" {
  description = "UpdateSessionAttributes-dev execution role ARN, or null when Connect is disabled."
  value       = try(module.UpdateSessionAttributes-dev[0].iam_role_arn, null)
}

output "conversion_of_queue_metrics_lambda_name" {
  value = try(module.conversion_of_queue_metrics[0].lambda_name, null)
}

output "conversion_of_queue_metrics_lambda_arn" {
  value = try(module.conversion_of_queue_metrics[0].lambda_arn, null)
}

output "conversion_of_queue_metrics_iam_role_arn" {
  value = try(module.conversion_of_queue_metrics[0].iam_role_arn, null)
}

output "lex_queueflow_callback_lambda_name" {
  value = try(module.lex_queueflow_callback[0].lambda_name, null)
}

output "lex_queueflow_callback_lambda_arn" {
  value = try(module.lex_queueflow_callback[0].lambda_arn, null)
}

output "lex_queueflow_callback_iam_role_arn" {
  value = try(module.lex_queueflow_callback[0].iam_role_arn, null)
}

output "lex_yesno_lambda_name" {
  value = try(module.lex_yesno[0].lambda_name, null)
}

output "lex_yesno_lambda_arn" {
  value = try(module.lex_yesno[0].lambda_arn, null)
}

output "lex_yesno_iam_role_arn" {
  value = try(module.lex_yesno[0].iam_role_arn, null)
}


output "connect_queue" {
  value = try({
    queue_id              = module.connect_queue[0].queue_id
    queue_arn             = module.connect_queue[0].queue_arn
    hours_of_operation_id = module.connect_queue[0].hours_of_operation_id
    quick_connect_ids     = module.connect_queue[0].quick_connect_ids
  }, null)
}

output "customer_number_data_table" {
  description = "CustomerNumberDataTable identifiers for flow configuration."

  value = try({
    name = "BTSGSD-V2V-US-CustomerNumberDataTable"
    arn  = aws_cloudformation_stack.customer_number_data_table[0].outputs["DataTableArn"]
    id   = local.customer_number_data_table_id
  }, null)
}

output "hr_transfer_data_table" {
  description = "Identifiers for the Connect HR transfer table named BTSGSD-HR_Transfer."

  value = try({
    name = "BTSGSD-V2V-US-BTSGSD-HR_Transfer"
    arn  = aws_cloudformation_stack.hr_transfer_data_table[0].outputs["DataTableArn"]
    id   = local.hr_transfer_data_table_id
  }, null)
}

output "survey_data_table" {
  description = "BTSGSD-Survey-DataTable identifiers for flow configuration."
  value = try({
    name = "BTSGSD-V2V-US-Survey-DataTable"
    arn  = aws_cloudformation_stack.survey_data_table[0].outputs["DataTableArn"]
    id   = local.survey_data_table_id
  }, null)
}

output "veeva_transfer_data_table" {
  description = "BTSGSD-Veeva_Transfer identifiers for lookups using country_LATAM and system_phonenumber."
  value = try({
    name = "BTSGSD-V2V-US-BTSGSD-Veeva_Transfer"
    arn  = aws_cloudformation_stack.veeva_transfer_data_table[0].outputs["DataTableArn"]
    id   = local.veeva_transfer_data_table_id
  }, null)
}

output "top_level_blocker_data_table" {
  description = "TopLevelBlockerMessage identifiers."
  value = try({
    name = "BTSGSD-V2V-US-TopLevelBlockerMessage"
    arn  = aws_cloudformation_stack.top_level_blocker_data_table[0].outputs["DataTableArn"]
    id   = local.top_level_blocker_data_table_id
  }, null)
}

output "bts_gsd_customer_number_data_table" {
  value = try({
    name = "BTSGSD-V2V-US-BTSGSD-CustomerNumber"
    arn  = aws_cloudformation_stack.bts_gsd_customer_number_data_table[0].outputs["DataTableArn"]
    id = element(
      reverse(split("/", aws_cloudformation_stack.bts_gsd_customer_number_data_table[0].outputs["DataTableArn"])),
      0
    )
  }, null)
}

output "survey_flow_arn" {
  value = try(aws_connect_contact_flow.survey[0].arn, null)
}

output "lex_yesno_published_version" {
  value = try(module.lex_yesno_bot[0].published_bot_version, null)
}

output "lex_yesno_alias_id" {
  value = try(module.lex_yesno_bot[0].bot_alias_id, null)
}

output "lex_yesno_alias_arn" {
  value = try(module.lex_yesno_bot[0].bot_alias_arn, null)
}

output "lex_yesno_log_group_name" {
  value = try(module.lex_yesno_log_group[0].name, null)
}

output "lex_yesno_log_group_arn" {
  value = try(module.lex_yesno_log_group[0].arn, null)
}

output "lex_yesno_text_logs_version" {
  value = try(module.lex_yesno_bot[0].alias_bot_version, null)
}

output "customer_queue_alias_id" {
  value = try(module.lex_customer_queue_flow_bot[0].bot_alias_id, null)
}

output "customer_queue_alias_arn" {
  value = try(module.lex_customer_queue_flow_bot[0].bot_alias_arn, null)
}

output "customer_queue_alias_version" {
  value = try(module.lex_customer_queue_flow_bot[0].alias_bot_version, null)
}

output "customer_queue_text_log_group_name" {
  value = try(module.customer_queue_lex_log_group[0].name, null)
}

output "vmx3_main_vm_module" {
  value = try({
    name = module.vmx3_main_vm_module[0].name
    arn  = module.vmx3_main_vm_module[0].arn
    id   = module.vmx3_main_vm_module[0].contact_flow_module_id
  }, null)
}
