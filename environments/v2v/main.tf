locals {
  common_tags = merge(var.common_tags, {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
    Platform    = "Amazon Connect V2V Translation"
    Application = var.app_name
    Network     = "No Custom VPC"
  })

  enabled_module_set       = toset([for module_name in var.enabled_modules : lower(module_name)])
  deploy_connect           = contains(local.enabled_module_set, "connect")
  deploy_connect_resources = contains(local.enabled_module_set, "connect-resources")
  deploy_lambda            = contains(local.enabled_module_set, "lambda")
  deploy_v2v               = contains(local.enabled_module_set, "v2v")
  deploy_code_signing      = contains(local.enabled_module_set, "code-signing")
}

locals {
  imported_flow_directory = "${path.module}/metadata/contact-flows"

  # Display names are independent of the JSON export filenames.
  # Flow types match the Metadata.type values in the complete exports.
  imported_flow_definitions = {
    fieldforce = {
      filename = "AbbVie_Fieldforce_Flow.json"
      name     = "BTSGSD-V2V-US-stdgsd_Fieldforce_Flow"
      type     = "CONTACT_FLOW"
    }

    customer_queue = {
      filename = "BTSGSD_Abbvie_CustomerQueueFlow.json"
      name     = "BTSGSD-V2V-US-BTSGSD_Abbvie_CustomerQueueFlow"
      type     = "CUSTOMER_QUEUE"
    }

    agent_transfer = {
      filename = "BTSGSD-AgentToAgentTransferFlow.json"
      name     = "BTSGSD-V2V-US-AgentToAgentTransferFlow"
      type     = "AGENT_TRANSFER"
    }

    outbound_whisper = {
      filename = "BTSGSD-OutboundWhisperFlow.json"
      name     = "BTSGSD-V2V-US-OutboundWhisperFlow"
      type     = "OUTBOUND_WHISPER"
    }

    transfer_customer_queue = {
      filename = "BTSGSD-Transfer-To-Agent-CustomerQueueFlow.json"
      name     = "BTSGSD-V2V-US-Transfer-To-Agent-CustomerQueueFlow"
      type     = "CUSTOMER_QUEUE"
    }

    voicemail = {
      filename = "BTSGSD-VoicemailFlow.json"
      name     = "BTSGSD-V2V-US-VoicemailFlow"
      type     = "CONTACT_FLOW"
    }

    hr = {
      filename = "AbbVie_HR.json"
      name     = "BTSGSD-V2V-US-btsgsd_HR"
      type     = "CONTACT_FLOW"
    }
  }

  # Stack outputs bind table lookups and defer dependency lookup until creation.
  rendered_imported_contact_flows = local.deploy_connect ? {
    for key, flow in local.imported_flow_definitions : key => {
      name = flow.name
      type = flow.type
      content = key == "customer_queue" ? replace(
        replace(
          file("${local.imported_flow_directory}/${flow.filename}"),
          "arn:aws:lambda:us-east-1:518902362956:function:conversionOfQueueMetrics",
          aws_connect_lambda_function_association.queue_metrics[0].function_arn
        ),
        "41573eb0-ae92-4b8a-bbe2-e4a32fb84801",
        local.survey_data_table_id
      ) : file("${local.imported_flow_directory}/${flow.filename}")
    }
  } : {}
}

module "connect_us_east_1" {
  count  = local.deploy_connect ? 1 : 0
  source = "../../v2v_modules/connect"

  providers = {
    aws = aws.us_east_1
  }

  project_name          = var.project_name
  environment           = var.environment
  aws_region            = "us-east-1"
  region_code           = "us-east-1"
  common_tags           = local.common_tags
  contact_center_alias  = var.contact_center_alias
  instance_alias        = var.connect_instance_alias
  expected_instance_arn = local.connect_target_instance_arn
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
  hr_flow_content = file(
    "${path.module}/metadata/contact-flows/AbbVie_HR.json"
  )
  imported_contact_flows = local.rendered_imported_contact_flows

  flow_dependency_python_executable = var.connect_flow_python_executable
  customer_queue_dependency_names   = var.connect_customer_queue_dependency_names
}

module "vmx3_main_vm_module" {
  count  = local.deploy_connect ? 1 : 0
  source = "../../v2v_modules/connect_contact_flow_module"

  providers = {
    aws = aws.us_east_1
  }

  instance_arn = module.connect_us_east_1[0].instance_arn
  name         = "VMX3_MAIN_VM_MODULE_BTSGSD-DEV-US-EAST-1"
  content_file = "${path.module}/metadata/contact-flow-modules/VMX3_Main_VM_Module_btsgsd-dev-us-east-1.json"

  voicemail_queue_arn    = var.vmx3_voicemail_queue_arn
  beep_prompt_arn        = var.vmx3_beep_prompt_arn
  survey_data_table_id   = local.survey_data_table_id
  timestamper_lambda_arn = var.vmx3_timestamper_lambda_arn
  tags                   = local.common_tags
}

module "btsgsd-Main-IB-Flow" {
  count  = local.deploy_connect ? 1 : 0
  source = "../../v2v_modules/btsgsd-Main-IB-Flow"

  providers = {
    aws = aws.us_east_1
  }

  instance_arn          = module.connect_us_east_1[0].instance_arn
  expected_instance_arn = local.connect_target_instance_arn
  flow_json             = file("${path.module}/metadata/contact-flows/BTSGSD-Main-IB-Flow.json")

  latam_queue_name           = var.main_ib_latam_queue_name
  phone_lookup_function_name = var.main_ib_phone_lookup_function_name

  flow_dependencies = {
    us_queue_arn            = module.connect_queue[0].queue_arn
    customer_queue_flow_arn = module.connect_us_east_1[0].customer_queue_flow_arn
    survey_flow_arn         = aws_connect_contact_flow.survey[0].arn
    agent_ui_flow_arn       = module.abbvie_views[0].flow_arn

    language_table_id = element(
      reverse(split(
        "/",
        aws_cloudformation_stack.bts_gsd_customer_number_data_table[0].outputs["DataTableArn"]
      )),
      0
    )

    survey_table_id  = local.survey_data_table_id
    blocker_table_id = local.top_level_blocker_data_table_id

    session_attributes_lambda_arn = module.BTSGSD-V2V-US-UpdateSessionAttributes[0].lambda_arn
    silence_guard_lambda_arn      = module.silence_guard-dev[0].function_arn
    queue_metrics_lambda_arn      = module.conversion_of_queue_metrics[0].lambda_arn
  }

  tags = local.common_tags

  depends_on = [
    module.BTSGSD-V2V-US-UpdateSessionAttributes,
    module.silence_guard-dev,
    aws_connect_lambda_function_association.queue_metrics
  ]
}

module "connect_views" {
  count  = local.deploy_connect ? 1 : 0
  source = "../../v2v_modules/connect_views"

  providers = {
    awscc = awscc.us_east_1
  }

  connect_instance_arn = module.connect_us_east_1[0].instance_arn
  view_name            = "BTSGSD-V2V-US-Customer Details"
  view_template        = file("${path.module}/metadata/views/customer_details.json")
  common_tags          = local.common_tags
}

module "abbvie_views" {
  count  = local.deploy_connect ? 1 : 0
  source = "../../v2v_modules/abbvie_views"

  providers = {
    aws = aws.us_east_1
  }

  connect_instance_arn      = module.connect_us_east_1[0].instance_arn
  customer_details_view_arn = module.connect_views[0].view_latest_arn

  flow_content = file(
    "${path.module}/metadata/contact-flows/abbvie_views.json"
  )

  common_tags = local.common_tags
}

module "support_agent_tools" {
  count  = local.dev_support_ai_enabled ? 1 : 0
  source = "../../v2v_modules/ai_agent_tools"

  namespace = module.agentcore_gateway[0].deployment.id

  # Exact gateway names from the current agentcore_gateway code.
  tool_names = [
    "BTSGSD-V2V-US-nexthink-handoff___handoff",
    "BTSGSD-V2V-US-snow-interaction___Interaction__Interaction",
    "BTSGSD-V2V-US-snow-userlookup___UserLookUp___UserLookUp",
  ]
}

module "btsgsd_support_agent" {
  count  = local.dev_support_ai_enabled ? 1 : 0
  source = "../../v2v_modules/connect_ai_agent"

  providers = {
    aws = aws.us_east_1
  }

  agent_name         = "BTSGSD-V2V-US-SupportAgent"
  prompt_name        = "BTSGSD-V2V-US-SupportAgent-prompt"
  stack_name         = "BTSGSD-V2V-US-SupportAgent"
  source_agent_name  = "SelfServiceOrchestratorVoice"
  source_prompt_name = "SelfServiceOrchestrationVoice"
  prompt_model_id    = "global.anthropic.claude-sonnet-5"

  assistant_id         = local.dev_ai_assistant_id
  connect_instance_arn = module.connect_us_east_1[0].instance_arn
  template_bucket_name = aws_s3_bucket.dev_ai_template[0].id
  prompt_yaml_file     = abspath("${path.module}/${var.dev_support_ai_prompt_file}")
  python_executable    = var.dev_support_ai_python_executable
  tags                 = local.dev_ai_tags
  tool_configurations  = module.support_agent_tools[0].tool_configurations

  depends_on = [
    module.connect_Integrations,
    aws_cloudformation_stack.dev_ai_domain,
    aws_s3_bucket_public_access_block.dev_ai_template,
    aws_s3_bucket_server_side_encryption_configuration.dev_ai_template
  ]
}

module "btsgsd_ai_survey_agent" {
  count  = local.dev_survey_ai_enabled ? 1 : 0
  source = "../../v2v_modules/connect_ai_agent"

  providers = {
    aws = aws.us_east_1
  }

  agent_name        = "BTSGSD-V2V-US-ai-survey-agent"
  prompt_name       = "BTSGSD-V2V-US-ai-survey-prompt"
  stack_name        = "BTSGSD-V2V-US-ai-survey-agent"
  source_agent_name = "SelfServiceOrchestratorVoice"
  prompt_model_id   = "global.anthropic.claude-sonnet-5"

  assistant_id         = local.dev_ai_assistant_id
  connect_instance_arn = module.connect_us_east_1[0].instance_arn
  template_bucket_name = aws_s3_bucket.dev_ai_template[0].id
  prompt_yaml_file     = abspath("${path.module}/${var.dev_survey_ai_prompt_file}")
  python_executable    = var.dev_survey_ai_python_executable
  tags                 = local.dev_ai_tags

  depends_on = [
    aws_cloudformation_stack.dev_ai_domain,
    aws_s3_bucket_public_access_block.dev_ai_template,
    aws_s3_bucket_server_side_encryption_configuration.dev_ai_template
  ]
}

# Publish the survey prompt under the existing assistant.
module "survey_ai_prompt" {
  count  = local.dev_survey_ai_enabled ? 1 : 0
  source = "../../v2v_modules/connect-ai-prompt"

  providers = {
    awscc = awscc.us_east_1
  }

  assistant_id     = local.dev_ai_assistant_id
  prompt_yaml_file = "${path.module}/metadata/prompts/BTSGSD-SSO-US-AI-Survey-Prompt.yaml"
}

# Keep the existing agent address and attach the published survey prompt.
module "connect_ai_agent" {
  count  = local.dev_survey_ai_enabled ? 1 : 0
  source = "../../v2v_modules/connect-ai-agent"

  providers = {
    aws   = aws.us_east_1
    awscc = awscc.us_east_1
  }

  assistant_id            = local.dev_ai_assistant_id
  connect_instance_arn    = module.connect_us_east_1[0].instance_arn
  orchestration_prompt_id = module.survey_ai_prompt[0].versioned_prompt_id
}

module "lambda_us_east_1" {
  code_signing_config_arn = var.lambda_code_signing_config_arn

  count  = local.deploy_lambda ? 1 : 0
  source = "../../v2v_modules/lambda"

  providers = {
    aws = aws.us_east_1
  }

  project_name       = var.project_name
  environment        = var.environment
  aws_region         = "us-east-1"
  region_code        = "us-east-1"
  common_tags        = local.common_tags
  name_prefix        = local.name_prefix
  lambda_name_suffix = var.lambda_name_suffix
}

module "lambda-ctr-survey" {
  code_signing_config_arn = var.lambda_code_signing_config_arn

  count  = contains(local.enabled_module_set, "lambda-ctr-survey") ? 1 : 0
  source = "../../v2v_modules/lambda-ctr-survey"

  providers = {
    aws = aws.us_east_1
  }

  source_file            = abspath("${path.module}/metadata/lambda-ctr/lambda_function_ctr_.py")
  handler                = "lambda_function_ctr_.lambda_handler"
  connect_instance_alias = var.connect_instance_alias
  common_tags            = local.common_tags
}

module "lambda-connect-daily-ctr-export" {
  code_signing_config_arn = var.lambda_code_signing_config_arn

  count  = contains(local.enabled_module_set, "lambda-connect-daily-ctr-export") ? 1 : 0
  source = "../../v2v_modules/lambda-connect-daily-ctr-export"

  providers = {
    aws = aws.us_east_1
  }

  source_file            = abspath("${path.module}/metadata/lambda-ctr/lambda_function_ctr_export.py")
  connect_instance_alias = var.connect_instance_alias
  common_tags            = local.common_tags
}

module "lambda-ctr-raw" {
  code_signing_config_arn = var.lambda_code_signing_config_arn

  count  = contains(local.enabled_module_set, "lambda-ctr-raw") ? 1 : 0
  source = "../../v2v_modules/lambda-ctr-raw"

  providers = {
    aws = aws.us_east_1
  }

  source_file            = abspath("${path.module}/metadata/lambda-ctr/lambda_function_ctr_raw.py")
  connect_instance_alias = var.connect_instance_alias
  common_tags            = local.common_tags
}

module "BTSGSD-V2V-US-SNOW" {
  code_signing_config_arn = var.lambda_code_signing_config_arn

  count  = contains(local.enabled_module_set, "btsgsd-v2v-us-snow") ? 1 : 0
  source = "../../v2v_modules/lambda-snow-btsgsd-dev"

  providers = {
    aws      = aws.us_east_1
    external = external
  }

  function_name         = "BTSGSD-V2V-US-SNOW"
  environment_variables = var.snow_lambda_environment_variables
  python_executable     = var.snow_lambda_python_executable
  reserved_concurrency  = var.snow_lambda_reserved_concurrency
  common_tags           = local.common_tags
}

module "iam-ctr" {
  count  = contains(local.enabled_module_set, "iam-ctr") ? 1 : 0
  source = "../../v2v_modules/iam-ctr"

  providers = {
    aws = aws.us_east_1
  }

  policy_name   = "BTSGSD-V2V-US-ctr-reporting-policy"
  s3_object_arn = "arn:aws:s3:::btsgsd-v2v-us-connect-reporting-bucket/connect/daily-interactions/*"

  role_names = [
    "BTSGSD-V2V-US-CTR-Survey-lambda-role",
    "BTSGSD-V2V-US-connect-daily-ctr-export-lambda-role",
    "BTSGSD-V2V-US-CTR-Raw-lambda-role"
  ]
}

module "s3_connect_reporting" {
  count  = contains(local.enabled_module_set, "s3_connect_reporting") ? 1 : 0
  source = "../../v2v_modules/s3_connect_reporting"

  providers = {
    aws = aws.us_east_1
  }

  bucket_name = "btsgsd-v2v-us-connect-reporting-bucket"
  common_tags = local.common_tags
}

data "aws_region" "current" {
  provider = aws.us_east_1
}

moved {
  from = module.s3[0]
  to   = module.s3_v2v[0]
}

moved {
  from = module.cloudfront[0]
  to   = module.cloudfront_v2v[0]
}

moved {
  from = module.cognito[0]
  to   = module.cognito_v2v[0]
}

moved {
  from = module.iam[0]
  to   = module.iam_v2v[0]
}

moved {
  from = module.ssm[0]
  to   = module.ssm_v2v[0]
}

locals {
  name_prefix = coalesce(var.resource_name_prefix, "BTSGSD-V2V-US")

  frontend_config = {
    backendRegion             = data.aws_region.current.region
    identityPoolId            = try(module.cognito_v2v[0].identity_pool_id, "")
    userPoolId                = try(module.cognito_v2v[0].user_pool_id, "")
    userPoolWebClientId       = try(module.cognito_v2v[0].user_pool_web_client_id, "")
    cognitoDomainURL          = try(module.cognito_v2v[0].cognito_domain_url, "")
    connectInstanceURL        = var.connect_instance_url
    connectInstanceRegion     = var.connect_instance_region
    transcribeRegion          = local.transcribe_region
    translateRegion           = local.translate_region
    pollyRegion               = local.polly_region
    bedrockRegion             = var.bedrock_region
    novaSonicModelId          = var.bedrock_model_id
    translationEnabled        = tostring(local.v2v_translation_enabled)
    proxyEnabled              = "false"
    ssoProviderName           = var.sso_enabled ? var.sso_provider_name : "not-defined"
    refreshTokenValidityHours = "12"
  }

  ssm_parameters = {
    cognitoDomainPrefix   = var.cognito_domain_prefix
    cognitoCallbackUrls   = join(",", var.cognito_callback_urls)
    cognitoLogoutUrls     = join(",", var.cognito_logout_urls)
    connectInstanceURL    = var.connect_instance_url
    connectInstanceRegion = var.connect_instance_region
    transcribeRegion      = local.transcribe_region
    translateRegion       = local.translate_region
    pollyRegion           = local.polly_region
    bedrockRegion         = var.bedrock_region
    novaSonicModelId      = var.bedrock_model_id
    translationEnabled    = tostring(local.v2v_translation_enabled)
    ssoEnabled            = tostring(var.sso_enabled)
    ssoProviderName       = var.sso_provider_name
    cspEnforced           = tostring(var.csp_enforced)
  }
}

module "s3_v2v" {
  count  = local.deploy_v2v ? 1 : 0
  source = "../../v2v_modules/s3_v2v"

  providers = {
    aws = aws.us_east_1
  }

  app_name          = var.app_name
  v2v_root_prefix   = var.v2v_root_prefix
  deploy_v2v_assets = var.deploy_v2v_assets
  v2v_dist_path     = var.v2v_dist_path
  frontend_config   = local.frontend_config
  common_tags       = local.common_tags
}

module "cloudfront_v2v" {
  count  = local.deploy_v2v ? 1 : 0
  source = "../../v2v_modules/cloudfront_v2v"

  providers = {
    aws = aws.us_east_1
  }

  name_prefix                     = local.name_prefix
  app_name                        = var.app_name
  v2v_root_prefix                 = var.v2v_root_prefix
  v2v_bucket_regional_domain_name = try(module.s3_v2v[0].v2v_bucket_regional_domain_name, "")
  v2v_log_bucket_domain_name      = try(module.s3_v2v[0].v2v_log_bucket_domain_name, "")
  polly_region                    = local.polly_region
  polly_proxy_enabled             = false
  translate_region                = local.translate_region
  translate_proxy_enabled         = false
  proxy_enabled                   = false
  translation_mode                = local.v2v_translation_mode
  cognito_domain_url              = "https://${var.cognito_domain_prefix}.auth.us-east-1.amazoncognito.com"
  connect_instance_url            = var.connect_instance_url
  connect_instance_region         = var.connect_instance_region
  csp_enforced                    = var.csp_enforced
  common_tags                     = local.common_tags
}

module "cognito_v2v" {
  count  = local.deploy_v2v ? 1 : 0
  source = "../../v2v_modules/cognito_v2v"

  providers = {
    aws = aws.us_east_1
  }

  app_name              = var.app_name
  frontend_client_name  = var.frontend_client_name
  sso_enabled           = var.sso_enabled
  sso_provider_name     = var.sso_provider_name
  cognito_domain_prefix = var.cognito_domain_prefix
  callback_urls         = distinct(concat(var.cognito_callback_urls, [module.cloudfront_v2v[0].v2v_url]))
  logout_urls           = distinct(concat(var.cognito_logout_urls, [module.cloudfront_v2v[0].v2v_url]))
  common_tags           = local.common_tags
}

module "iam_v2v" {
  count  = local.deploy_v2v ? 1 : 0
  source = "../../v2v_modules/iam_v2v"

  providers = {
    aws = aws.us_east_1
  }

  name_prefix       = local.name_prefix
  identity_pool_id  = try(module.cognito_v2v[0].identity_pool_id, "")
  translation_mode  = local.v2v_translation_mode
  bedrock_region    = var.bedrock_region
  bedrock_model_id  = var.bedrock_model_id
  transcribe_region = local.transcribe_region
  translate_region  = local.translate_region
  polly_region      = local.polly_region
  common_tags       = local.common_tags
}

module "ssm_v2v" {
  count  = local.deploy_v2v ? 1 : 0
  source = "../../v2v_modules/ssm_v2v"

  providers = {
    aws = aws.us_east_1
  }

  ssm_hierarchy = var.ssm_hierarchy
  parameters    = local.ssm_parameters
  common_tags   = local.common_tags
}

module "BTSGSD-V2V-US-ServiceNow_Interaction" {
  code_signing_config_arn = var.lambda_code_signing_config_arn

  count  = contains(local.enabled_module_set, "btsgsd-v2v-us-servicenow_interaction") ? 1 : 0
  source = "../../v2v_modules/lambda-servicenow-interaction"

  providers = {
    aws      = aws.us_east_1
    external = external
  }

  common_tags           = local.common_tags
  environment_variables = var.servicenow_interaction_environment_variables
  python_executable     = var.servicenow_interaction_python_executable
  reserved_concurrency  = var.servicenow_interaction_reserved_concurrency
}

module "BTSGSD-V2V-US-Nextthink_Handoff" {
  code_signing_config_arn = var.lambda_code_signing_config_arn

  count  = contains(local.enabled_module_set, "btsgsd-v2v-us-nextthink_handoff") ? 1 : 0
  source = "../../v2v_modules/lambda-nextthink-handoff"

  providers = {
    aws      = aws.us_east_1
    external = external
  }

  common_tags           = local.common_tags
  python_executable     = var.nexthink_handoff_python_executable
  environment_variables = var.nexthink_handoff_environment_variables
  reserved_concurrency  = var.nexthink_handoff_reserved_concurrency
  secret_kms_key_arn    = var.nexthink_handoff_secret_kms_key_arn
}

# Preserve the existing stack's ownership in the Dev Connect state.
moved {
  from = aws_cloudformation_stack.agentcore_gateway[0]
  to   = module.agentcore_gateway[0].aws_cloudformation_stack.gateway
}

module "agentcore_gateway" {
  count  = local.deploy_connect && var.agentcore_gateway_enabled ? 1 : 0
  source = "../../v2v_modules/agentcore_gateway"

  providers = {
    aws = aws.us_east_1
  }

  stack_name             = "BTSGSD-V2V-US-AgentCore-DefaultGateway"
  gateway_name           = "BTSGSD-V2V-US-gateway-quick-start"
  role_name              = "BTSGSD-V2V-US-agentcore-default-gateway-role"
  lambda_arn             = "arn:aws:lambda:us-east-1:518902362956:function:BTSGSD-V2V-US-SNOW"
  interaction_lambda_arn = "arn:aws:lambda:us-east-1:518902362956:function:BTSGSD-V2V-US-ServiceNow_Interaction"
  nexthink_lambda_arn    = "arn:aws:lambda:us-east-1:518902362956:function:BTSGSD-V2V-US-Nextthink_Handoff"
  connect_url            = var.connect_instance_url
  gateway_id_audience    = var.agentcore_gateway_id_audience
  common_tags            = local.common_tags
}

module "connect_Integrations" {
  count = (
    local.deploy_connect &&
    var.agentcore_gateway_enabled &&
    var.connect_integrations_enabled
  ) ? 1 : 0

  source = "../../v2v_modules/connect_Integrations"

  providers = {
    aws = aws.us_east_1
  }

  stack_name           = "BTSGSD-V2V-US-Connect-SNOW-MCP-Integration"
  display_name         = "BTSGSD-V2V-US-btsgsd_SNOW"
  connect_instance_arn = local.connect_target_instance_arn
  gateway_id           = module.agentcore_gateway[0].deployment.id
  gateway_url          = module.agentcore_gateway[0].deployment.url
  common_tags          = local.common_tags
}

module "secrets_manager" {
  count  = contains(local.enabled_module_set, "secrets_manager") ? 1 : 0
  source = "../../v2v_modules/secrets_manager"

  providers = {
    aws = aws.us_east_1
  }

  secrets     = var.secrets_manager_secrets
  common_tags = local.common_tags
}

# Deploys with the btsgsd-intent-kb selection.
module "s3_intent_kb" {
  count  = contains(local.enabled_module_set, "btsgsd-intent-kb") ? 1 : 0
  source = "../../v2v_modules/s3_intent_kb"

  providers = {
    aws = aws.us_east_1
  }

  bucket_name = "btsgsd-v2v-us-intent-kb"
}

# Deploys with the lex_bot selection.
# Builds and publishes the multilingual IT Support Q in Connect bot.
module "lex_bot" {
  count  = contains(local.enabled_module_set, "lex_bot") ? 1 : 0
  source = "../../v2v_modules/lex_bot"

  providers = {
    aws   = aws.us_east_1
    awscc = awscc.us_east_1
  }

  bot_name       = "BTSGSD-V2V-US-IT-Support_Agent"
  child_directed = true
  locale_ids     = ["en_US", "hi_IN", "pt_BR", "es_419"]

  it_support_configuration = {
    assistant_arn        = "arn:aws:wisdom:us-east-1:518902362956:assistant/bc274e3f-380d-45e7-968f-2d19f92acd74"
    connect_instance_arn = "arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d"
    alias_name           = "btsgsd-alias-dev-sso"
  }
}

module "lex_yesno_bot" {
  count  = contains(local.enabled_module_set, "lex_bot") ? 1 : 0
  source = "../../v2v_modules/lex_bot"

  providers = {
    aws   = aws.us_east_1
    awscc = awscc.us_east_1
  }

  bot_name       = "BTSGSD-V2V-US-yesNo"
  locale_ids     = ["en_US", "pt_BR", "es_419"]
  child_directed = false

  enable_english_yesno_intents    = true
  enable_portuguese_yesno_intents = true
  enable_spanish_yesno_intents    = true

  publish_yesno_version = true

  alias_configuration = {
    name                 = "BTSGSD-V2V-US-DEV"
    lambda_function_arn  = data.aws_lambda_function.lex_yesno_alias_hook[0].arn
    connect_instance_arn = "arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d"
    text_log_group_arn   = data.aws_cloudwatch_log_group.lex_yesno_text_logs[0].arn
  }
}

# The Lambda must exist before this lookup. It belongs to the connect group;
# account for this dependency when deploying the lex_bot group for the first time.
data "aws_lambda_function" "lex_yesno_alias_hook" {
  count    = contains(local.enabled_module_set, "lex_bot") ? 1 : 0
  provider = aws.us_east_1

  function_name = "BTSGSD-V2V-US-lex-yesNo"
}

# Create the log group using the cloudwatch_log_group deployment group first.
data "aws_cloudwatch_log_group" "lex_yesno_text_logs" {
  count    = contains(local.enabled_module_set, "lex_bot") ? 1 : 0
  provider = aws.us_east_1
  name     = "/aws/lex/BTSGSD-V2V-US-yesNo"
}

module "lex_customer_queue_flow_bot" {
  count  = contains(local.enabled_module_set, "lex_bot") ? 1 : 0
  source = "../../v2v_modules/lex_bot"

  providers = {
    aws   = aws.us_east_1
    awscc = awscc.us_east_1
  }

  bot_name       = "BTSGSD-V2V-US-customerQueueFlowBot"
  locale_ids     = ["en_US", "es_419", "pt_BR"]
  child_directed = false

  enable_english_customer_queue_intents    = true
  enable_portuguese_customer_queue_intents = true
  enable_spanish_customer_queue_intents    = true

  # Build all three locales, then publish the version used by the alias.
  # AWS assigns Version 1 only on this bot's first-ever publication.
  publish_customer_queue_version = true

  alias_configuration = {
    name                 = "BTSGSD-V2V-US-DEV"
    lambda_function_arn  = data.aws_lambda_function.customer_queue_alias_hook[0].arn
    connect_instance_arn = "arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d"
    text_log_group_arn   = module.customer_queue_lex_log_group[0].arn
  }
}

# The queue metrics Lambda belongs to the connect group and must already exist.
# Its unqualified ARN invokes $LATEST for every locale on the customer queue alias.
data "aws_lambda_function" "customer_queue_alias_hook" {
  count    = contains(local.enabled_module_set, "lex_bot") ? 1 : 0
  provider = aws.us_east_1

  function_name = "BTSGSD-V2V-US-conversionOfQueueMetrics"
}

# Owned by lex_bot so the log group is created with the customer queue alias.
module "customer_queue_lex_log_group" {
  count  = contains(local.enabled_module_set, "lex_bot") ? 1 : 0
  source = "../../v2v_modules/cloudwatch_log_group"

  providers = {
    aws = aws.us_east_1
  }

  log_group_name = "/aws/lex/BTSGSD-V2V-US-customerQueueFlowBot"
}

module "lex_aiagent_survey_bot" {
  count  = contains(local.enabled_module_set, "lex_bot") ? 1 : 0
  source = "../../v2v_modules/lex_bot"

  providers = {
    aws   = aws.us_east_1
    awscc = awscc.us_east_1
  }

  bot_name       = "BTSGSD-V2V-US-AIAgent-Survey"
  locale_ids     = ["en_US", "pt_BR", "es_419"]
  child_directed = true
}

# Invoke this Lambda after the Connect assistant block in the contact flow.
module "BTSGSD-V2V-US-UpdateSessionAttributes" {
  code_signing_config_arn = var.lambda_code_signing_config_arn

  count  = local.deploy_connect ? 1 : 0
  source = "../../v2v_modules/UpdateSessionAttributes-dev"

  providers = {
    aws     = aws.us_east_1
    archive = archive
  }

  function_name        = "BTSGSD-V2V-US-UpdateSessionAttributes"
  source_file          = "${path.module}/metadata/scr_lambda/lambda_function.py"
  zip_path             = "${path.module}/metadata/scr_lambda/lambda_function.zip"
  connect_instance_arn = module.connect_us_east_1[0].instance_arn
  assistant_id         = local.dev_ai_assistant_id
  common_tags          = local.common_tags
}

# Deploys with the connect selection.
module "silence_guard-dev" {
  code_signing_config_arn = var.lambda_code_signing_config_arn

  count  = local.deploy_connect ? 1 : 0
  source = "../../v2v_modules/silence_guard-dev"

  providers = {
    aws = aws.us_east_1
  }

  connect_instance_arn = module.connect_us_east_1[0].instance_arn
  common_tags          = local.common_tags
}

# Deploys with the existing Connect selection.
module "conversion_of_queue_metrics" {
  code_signing_config_arn = var.lambda_code_signing_config_arn

  count  = local.deploy_connect ? 1 : 0
  source = "../../v2v_modules/conversionOfQueueMetrics-dev"

  providers = {
    aws = aws.us_east_1
  }

  function_name  = "BTSGSD-V2V-US-conversionOfQueueMetrics"
  iam_role_name  = "conversionOfQueueMetrics-role-ox32eazp"
  log_group_name = "/aws/lambda/BTSGSD-V2V-US-conversionOfQueueMetrics"
  zip_path       = "${path.module}/metadata/conversionOfQueueMetrics-dev_lambda/lambda_function.zip"

  environment_variables = {
    TableName   = "BTSGSD-V2V-US-queueInfo"
    LOG_LEVEL   = "DEBUG"
    TTL_SECONDS = "86400"
  }

  common_tags = local.common_tags
}

# Deploys with the existing Connect selection.
module "lex_queueflow_callback" {
  code_signing_config_arn = var.lambda_code_signing_config_arn

  count  = local.deploy_connect ? 1 : 0
  source = "../../v2v_modules/BTSGSD-lex-QueueFlow-Callback-dev"

  providers = {
    aws = aws.us_east_1
  }

  function_name  = "BTSGSD-V2V-US-lex-QueueFlow-Callback"
  iam_role_name  = "BTSGSD-lex-QueueFlow-Callback-role-i0v0kqis"
  log_group_name = "/aws/lambda/BTSGSD-V2V-US-lex-QueueFlow-Callback"

  zip_path = "${path.module}/metadata/BTSGSD-lex-QueueFlow-Callback-dev_lambda/lambda_function.zip"

  layer_arn = "arn:aws:lambda:us-east-1:615299751070:layer:AWSOpenTelemetryDistroPython:32"

  environment_variables = {
    LOWER_THRESHOLD         = "0.4"
    UPPER_THRESHOLD         = "0.7"
    LOG_LEVEL               = "DEBUG"
    AWS_LAMBDA_EXEC_WRAPPER = "/opt/otel-instrument"
  }

  lex_bot_alias_arn = var.lex_queueflow_callback_bot_alias_arn
  common_tags       = local.common_tags
}

# Deploys with the existing Connect selection.
module "lex_yesno" {
  code_signing_config_arn = var.lambda_code_signing_config_arn

  count  = local.deploy_connect ? 1 : 0
  source = "../../v2v_modules/BTSGSD-lex-yesNo-dev"

  providers = {
    aws = aws.us_east_1
  }

  function_name  = "BTSGSD-V2V-US-lex-yesNo"
  iam_role_name  = "BTSGSD-lex-yesNo-role-ow5vzdof"
  log_group_name = "/aws/lambda/BTSGSD-V2V-US-lex-yesNo"

  zip_path = "${path.module}/metadata/BTSGSD-lex-yesNo-dev_lambda-dev_lambda/lambda_function.zip"

  layer_arn = "arn:aws:lambda:us-east-1:615299751070:layer:AWSOpenTelemetryDistroPython:32"

  environment_variables = {
    LOWER_THRESHOLD         = "0.4"
    UPPER_THRESHOLD         = "0.7"
    LOG_LEVEL               = "DEBUG"
    AWS_LAMBDA_EXEC_WRAPPER = "/opt/otel-instrument"
  }

  lex_bot_alias_arn = var.lex_yesno_bot_alias_arn
  common_tags       = local.common_tags
}

data "aws_kms_key" "queue_info" {
  count    = contains(local.enabled_module_set, "dynamodb") ? 1 : 0
  provider = aws.us_east_1

  key_id = "alias/IAI"
}

module "queue_info_dynamodb" {
  count  = contains(local.enabled_module_set, "dynamodb") ? 1 : 0
  source = "../../v2v_modules/dynamodb"

  providers = {
    aws = aws.us_east_1
  }

  table_name  = "BTSGSD-V2V-US-queueInfo"
  kms_key_arn = data.aws_kms_key.queue_info[0].arn
}

module "cloudwatch_log_group" {
  count  = contains(local.enabled_module_set, "cloudwatch_log_group") ? 1 : 0
  source = "../../v2v_modules/cloudwatch_log_group"

  providers = {
    aws = aws.us_east_1
  }

  log_group_name = "/aws/connect/BTSGSD-V2V-US-ai-agent-logs"
}

# Creates the group only; Lex alias conversation logging remains disabled.
module "lex_yesno_log_group" {
  count  = contains(local.enabled_module_set, "cloudwatch_log_group") ? 1 : 0
  source = "../../v2v_modules/cloudwatch_log_group"

  providers = {
    aws = aws.us_east_1
  }

  log_group_name = "/aws/lex/BTSGSD-V2V-US-yesNo"
}

import {
  for_each = contains(local.enabled_module_set, "secrets_manager") ? var.secrets_manager_existing_arns : {}

  to = module.secrets_manager[0].aws_secretsmanager_secret.this[each.key]
  id = each.value
}


# Configuration consolidated from ai_agent.tf
locals {
  dev_ai_domain_enabled  = var.dev_ai_domain_enabled && local.deploy_connect
  dev_ai_enabled         = var.dev_ai_agent_enabled && local.deploy_connect
  dev_survey_ai_enabled  = var.dev_survey_ai_agent_enabled && local.deploy_connect
  dev_support_ai_enabled = var.dev_support_ai_agent_enabled && local.deploy_connect
  # Retain the private bucket while its name is configured, even without an agent.
  dev_ai_template_bucket_enabled = var.dev_ai_template_bucket != null && local.deploy_connect
  dev_ai_assistant_id            = local.dev_ai_domain_enabled ? aws_cloudformation_stack.dev_ai_domain[0].outputs["AssistantId"] : var.dev_ai_assistant_id
  dev_ai_name_prefix             = local.name_prefix
  dev_ai_tags = merge(local.common_tags, {
    Platform             = "Amazon Connect AI Agent"
    AmazonConnectEnabled = "True"
  })

  # Read the prompt unchanged and let Connect resolve its runtime placeholders.
  dev_ai_template = local.dev_ai_enabled ? jsonencode({
    AWSTemplateFormatVersion = "2010-09-09"
    Resources = {
      DevPrompt = {
        Type = "AWS::Wisdom::AIPrompt"
        Properties = {
          AssistantId  = local.dev_ai_assistant_id
          Name         = "${local.dev_ai_name_prefix}-AgentAssistanceOrchestration"
          Type         = "ORCHESTRATION"
          ApiFormat    = "MESSAGES"
          TemplateType = "TEXT"
          ModelId      = var.dev_ai_prompt_model_id
          Tags         = local.dev_ai_tags
          TemplateConfiguration = {
            TextFullAIPromptEditTemplateConfiguration = {
              Text = file("${path.module}/${var.dev_ai_prompt_file}")
            }
          }
        }
      }

      DevPromptVersion = {
        Type = "AWS::Wisdom::AIPromptVersion"
        Properties = {
          AssistantId         = local.dev_ai_assistant_id
          AIPromptId          = { "Fn::GetAtt" = ["DevPrompt", "AIPromptId"] }
          ModifiedTimeSeconds = { "Fn::GetAtt" = ["DevPrompt", "ModifiedTimeSeconds"] }
        }
      }

      DevAIAgent = {
        Type = "AWS::Wisdom::AIAgent"
        Properties = {
          AssistantId = local.dev_ai_assistant_id
          Name        = "${local.dev_ai_name_prefix}-customer-service-ai"
          Description = var.dev_ai_agent_test_mode ? "Prompt-only Dev smoke-test agent without retrieval or action tools." : "Dev customer-service orchestration agent."
          Type        = "ORCHESTRATION"
          Tags        = local.dev_ai_tags
          Configuration = {
            OrchestrationAIAgentConfiguration = merge({
              ConnectInstanceArn = module.connect_us_east_1[0].instance_arn
              Locale             = "en_US"
              OrchestrationAIPromptId = {
                "Fn::Join" = [":", [
                  { "Fn::GetAtt" = ["DevPrompt", "AIPromptId"] },
                  { "Fn::GetAtt" = ["DevPromptVersion", "VersionNumber"] }
                ]]
              }
            }, try(length(var.dev_ai_tools) > 0, false) ? { ToolConfigurations = var.dev_ai_tools } : {})
          }
        }
      }

      DevAIAgentVersion = {
        Type = "AWS::Wisdom::AIAgentVersion"
        Properties = {
          AssistantId         = local.dev_ai_assistant_id
          AIAgentId           = { "Fn::GetAtt" = ["DevAIAgent", "AIAgentId"] }
          ModifiedTimeSeconds = { "Fn::GetAtt" = ["DevAIAgent", "ModifiedTimeSeconds"] }
        }
      }
    }

    Outputs = {
      ConnectInstanceArn = {
        Value = module.connect_us_east_1[0].instance_arn
      }
      AssistantId = {
        Value = local.dev_ai_assistant_id
      }
      AgentId = {
        Value = { "Fn::GetAtt" = ["DevAIAgent", "AIAgentId"] }
      }
      AgentVersion = {
        Value = { "Fn::GetAtt" = ["DevAIAgentVersion", "VersionNumber"] }
      }
      PromptId = {
        Value = { "Fn::GetAtt" = ["DevPrompt", "AIPromptId"] }
      }
      PromptVersion = {
        Value = { "Fn::GetAtt" = ["DevPromptVersion", "VersionNumber"] }
      }
    }
  }) : null
}

resource "aws_cloudformation_stack" "dev_ai_domain" {
  count    = local.dev_ai_domain_enabled ? 1 : 0
  provider = aws.us_east_1
  name     = "${local.dev_ai_name_prefix}-ai-domain"
  tags     = local.dev_ai_tags

  template_body = jsonencode({
    AWSTemplateFormatVersion = "2010-09-09"
    Resources = {
      DevAssistant = {
        Type = "AWS::Wisdom::Assistant"
        Properties = {
          Name        = "${local.dev_ai_name_prefix}-ai-domain"
          Description = "AI agent domain for the Dev Amazon Connect instance."
          Type        = "AGENT"
          Tags        = [for key, value in local.dev_ai_tags : { Key = key, Value = value }]
        }
      }
      DevConnectAssociation = {
        Type = "AWS::Connect::IntegrationAssociation"
        Properties = {
          # CloudFormation requires the instance ARN, not the UUID, here.
          InstanceId      = module.connect_us_east_1[0].instance_arn
          IntegrationType = "WISDOM_ASSISTANT"
          IntegrationArn  = { "Fn::GetAtt" = ["DevAssistant", "AssistantArn"] }
        }
      }
    }
    Outputs = {
      DomainName = {
        Value = "${local.dev_ai_name_prefix}-ai-domain"
      }
      AssistantId = {
        Value = { Ref = "DevAssistant" }
      }
      AssistantArn = {
        Value = { "Fn::GetAtt" = ["DevAssistant", "AssistantArn"] }
      }
      ConnectInstanceArn = {
        Value = module.connect_us_east_1[0].instance_arn
      }
    }
  })
}

resource "aws_s3_bucket" "dev_ai_template" {
  count         = local.dev_ai_template_bucket_enabled ? 1 : 0
  provider      = aws.us_east_1
  bucket        = var.dev_ai_template_bucket
  force_destroy = false
  tags          = local.dev_ai_tags
}

resource "aws_s3_bucket_public_access_block" "dev_ai_template" {
  count    = local.dev_ai_template_bucket_enabled ? 1 : 0
  provider = aws.us_east_1
  bucket   = aws_s3_bucket.dev_ai_template[count.index].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "dev_ai_template" {
  count    = local.dev_ai_template_bucket_enabled ? 1 : 0
  provider = aws.us_east_1
  bucket   = aws_s3_bucket.dev_ai_template[count.index].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# The full prompt exceeds CloudFormation's inline template size limit.
resource "aws_s3_object" "dev_ai_template" {
  count        = local.dev_ai_enabled ? 1 : 0
  provider     = aws.us_east_1
  bucket       = aws_s3_bucket.dev_ai_template[count.index].id
  key          = "ai-agents/${sha256(local.dev_ai_template)}.json"
  content      = local.dev_ai_template
  content_type = "application/json"
  tags         = local.dev_ai_tags

  depends_on = [
    aws_s3_bucket_public_access_block.dev_ai_template,
    aws_s3_bucket_server_side_encryption_configuration.dev_ai_template
  ]

  lifecycle {
    create_before_destroy = true
  }
}

resource "terraform_data" "dev_ai_model_validation" {
  count = local.dev_ai_enabled ? 1 : 0

  triggers_replace = {
    assistant_id = local.dev_ai_assistant_id
    model_id     = var.dev_ai_prompt_model_id
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      DEV_AI_ASSISTANT_ID = local.dev_ai_assistant_id
      DEV_AI_MODEL_ID     = var.dev_ai_prompt_model_id
      AWS_REGION          = "us-east-1"
      AWS_DEFAULT_REGION  = "us-east-1"
      AWS_PAGER           = ""
    }
    command = <<-BASH
      set -euo pipefail
      set -f

      if ! command -v aws >/dev/null 2>&1; then
        echo "Dev AI model validation requires AWS CLI v2 on the Terraform runner." >&2
        exit 1
      fi

      available_models=$(aws qconnect list-models \
        --assistant-id "$DEV_AI_ASSISTANT_ID" \
        --ai-prompt-type ORCHESTRATION \
        --region us-east-1 \
        --query 'modelSummaries[].modelId' \
        --output text \
        --no-cli-pager)

      for model in $available_models; do
        if [ "$model" = "$DEV_AI_MODEL_ID" ]; then
          echo "Verified Dev orchestration model: $DEV_AI_MODEL_ID"
          exit 0
        fi
      done

      echo "Model '$DEV_AI_MODEL_ID' is not available for the Dev assistant in us-east-1." >&2
      echo "Available orchestration model IDs:" >&2
      printf '%s\n' "$available_models" >&2
      echo "Set dev_ai_prompt_model_id to an exact available ID and generate a fresh plan." >&2
      exit 1
    BASH
  }
}

resource "aws_cloudformation_stack" "dev_ai_agent" {
  count    = local.dev_ai_enabled ? 1 : 0
  provider = aws.us_east_1
  name     = "${local.dev_ai_name_prefix}-ai-agent"
  tags     = local.dev_ai_tags

  template_url = "https://s3.us-east-1.amazonaws.com/${aws_s3_bucket.dev_ai_template[count.index].id}/${aws_s3_object.dev_ai_template[count.index].key}"

  depends_on = [terraform_data.dev_ai_model_validation]
}

# Configuration consolidated from ai_security_profiles.tf
locals {
  dev_ai_admin_security_profile_enabled = var.dev_ai_admin_security_profile_enabled && local.deploy_connect
}

# Look up the built-in profile even when creation of a human admin user is disabled.
data "aws_connect_security_profile" "ai_admin" {
  count       = local.dev_ai_admin_security_profile_enabled ? 1 : 0
  provider    = aws.us_east_1
  instance_id = module.connect_us_east_1[0].instance_id
  name        = "Admin"
}

# The pinned AWS provider and AWS::Wisdom::AIAgent do not expose the separate
# Connect security-profile association API. Run it during apply, never planning.
resource "terraform_data" "dev_ai_admin_security_profiles" {
  count = local.dev_ai_admin_security_profile_enabled ? 1 : 0

  input = {
    python_executable = var.dev_ai_security_profile_python_executable
    script_path       = abspath("${path.module}/../../v2v_modules/connect_ai_agent/assign_admin_security_profile.py")
    config = {
      assistant_id         = local.dev_ai_assistant_id
      connect_instance_arn = module.connect_us_east_1[0].instance_arn
      admin_profile_id     = data.aws_connect_security_profile.ai_admin[0].security_profile_id
      region               = "us-east-1"
    }
  }

  triggers_replace = {
    assistant_id     = local.dev_ai_assistant_id
    admin_profile_id = data.aws_connect_security_profile.ai_admin[0].security_profile_id
    instance_arn     = module.connect_us_east_1[0].instance_arn
    python           = var.dev_ai_security_profile_python_executable
    script_hash      = filesha256("${path.module}/../../v2v_modules/connect_ai_agent/assign_admin_security_profile.py")
    survey_agent     = try(module.btsgsd_ai_survey_agent[0].deployment, null)
    support_agent    = try(module.btsgsd_support_agent[0].deployment, null)
    legacy_agent     = try(aws_cloudformation_stack.dev_ai_agent[0].outputs, null)
  }

  provisioner "local-exec" {
    command = "\"${self.input.python_executable}\" \"${self.input.script_path}\""
    environment = {
      AI_AGENT_ADMIN_PROFILE_CONFIG = jsonencode(self.input.config)
    }
  }
}

# Configuration consolidated from connect_queue.tf
module "connect_queue" {
  count  = local.deploy_connect ? 1 : 0
  source = "../../v2v_modules/connect-queue"

  providers = {
    aws = aws.us_east_1
  }

  instance_alias           = var.connect_instance_alias
  queue_name               = var.queue_name
  outbound_phone_number_id = local.resolved_outbound_phone_number_id
  outbound_flow_name       = "Default outbound"

  tags = merge(local.common_tags, {
    Env = "Dev"
    Org = "btsgsd"
  })
}

# Configuration consolidated from connect_target.tf
# Resolve the existing POC instance rather than retaining a copied Dev UUID.
data "aws_connect_instance" "target" {
  count    = local.deploy_connect || local.deploy_connect_resources ? 1 : 0
  provider = aws.us_east_1

  instance_alias = var.connect_instance_alias
}

locals {
  connect_target_instance_id  = try(data.aws_connect_instance.target[0].id, null)
  connect_target_instance_arn = try(data.aws_connect_instance.target[0].arn, null)
}

# Configuration consolidated from customer_queue_dependencies.tf
resource "aws_lambda_permission" "queue_metrics_connect" {
  count    = local.deploy_connect ? 1 : 0
  provider = aws.us_east_1

  statement_id  = "AllowConnectCustomerQueueMetrics"
  action        = "lambda:InvokeFunction"
  function_name = module.conversion_of_queue_metrics[0].lambda_name
  principal     = "connect.amazonaws.com"

  source_arn     = module.connect_us_east_1[0].instance_arn
  source_account = split(":", module.connect_us_east_1[0].instance_arn)[4]
}

resource "aws_connect_lambda_function_association" "queue_metrics" {
  count    = local.deploy_connect ? 1 : 0
  provider = aws.us_east_1

  instance_id  = module.connect_us_east_1[0].instance_id
  function_arn = module.conversion_of_queue_metrics[0].lambda_arn

  depends_on = [aws_lambda_permission.queue_metrics_connect]
}

# Configuration consolidated from data_table.tf
# Creates CustomerNumberDataTable with the supplied CSV rows. Phone numbers
# lose Excel's leading apostrophe so the primary key matches the dialed number.
locals {
  customer_number_csv = <<-CSV
"system_phonenumber","amazon_speaking_engine","amazon_speaking_style","amazon_voice","country","error_message","hr_contact","language_code","language_name","Region","welcome_prompt"
"'+18335162999","neural","conversational","Joanna","United States","Sorry, I didn’t get that. Let’s try again.","'+558008920901","en-US","English","","Welcome to AbbVie Service Desk. Please briefly describe your issue."
"'+18447706127","neural","conversational","Katie","","Sorry, I didn’t get that. Let’s try again.","","en-US","English","","Welcome to AbbVie Service Desk. Please briefly describe your issue."
CSV

  customer_number_raw_rows = csvdecode(trimspace(local.customer_number_csv))
  customer_number_columns  = keys(local.customer_number_raw_rows[0])

  customer_number_rows = {
    for row in local.customer_number_raw_rows :
    trimprefix(trimspace(row.system_phonenumber), "'") => {
      for column, value in row :
      column => (
        contains(["system_phonenumber", "hr_contact"], column)
        ? trimprefix(trimspace(value), "'")
        : value
      )
    }
  }

  customer_number_template = {
    AWSTemplateFormatVersion = "2010-09-09"
    Description              = "Amazon Connect CustomerNumberDataTable configuration."

    Parameters = {
      InstanceArn = {
        Type = "String"
      }
    }

    Resources = merge(
      {
        CustomerNumberTable = {
          Type = "AWS::Connect::DataTable"
          Properties = {
            InstanceArn    = { Ref = "InstanceArn" }
            Name           = "BTSGSD-V2V-US-CustomerNumberDataTable"
            Description    = "Language and greeting configuration by dialed phone number."
            Status         = "PUBLISHED"
            TimeZone       = "UTC"
            ValueLockLevel = "NONE"

            Tags = [
              for key, value in merge(local.common_tags, {
                Name = "BTSGSD-V2V-US-CustomerNumberDataTable"
                }) : {
                Key   = key
                Value = value
              }
            ]
          }
        }
      },
      {
        for column in local.customer_number_columns :
        "Attribute${replace(column, "_", "")}" => {
          Type = "AWS::Connect::DataTableAttribute"
          Properties = {
            InstanceArn  = { Ref = "InstanceArn" }
            DataTableArn = { "Fn::GetAtt" = ["CustomerNumberTable", "Arn"] }
            Name         = column
            ValueType    = "TEXT"
            Primary      = column == "system_phonenumber"
          }
        }
      },
      {
        for phone_number, row in local.customer_number_rows :
        "Record${replace(phone_number, "+", "")}" => {
          Type = "AWS::Connect::DataTableRecord"
          Properties = {
            InstanceArn  = { Ref = "InstanceArn" }
            DataTableArn = { "Fn::GetAtt" = ["CustomerNumberTable", "Arn"] }

            DataTableRecord = {
              PrimaryValues = [
                {
                  AttributeId = {
                    "Fn::GetAtt" = [
                      "Attributesystemphonenumber",
                      "AttributeId"
                    ]
                  }
                  AttributeValue = phone_number
                }
              ]

              Values = [
                for column in local.customer_number_columns : {
                  AttributeId = {
                    "Fn::GetAtt" = [
                      "Attribute${replace(column, "_", "")}",
                      "AttributeId"
                    ]
                  }
                  AttributeValue = row[column]
                }
                if column != "system_phonenumber"
              ]
            }
          }
        }
      }
    )

    Outputs = {
      DataTableArn = {
        Value = {
          "Fn::GetAtt" = ["CustomerNumberTable", "Arn"]
        }
      }
    }
  }

  customer_number_data_table_id = try(element(
    reverse(split("/", aws_cloudformation_stack.customer_number_data_table[0].outputs["DataTableArn"])),
    0
  ), null)
}

resource "aws_cloudformation_stack" "customer_number_data_table" {
  count    = local.deploy_connect ? 1 : 0
  provider = aws.us_east_1

  name          = "BTSGSD-V2V-US-CustomerNumberDataTable"
  template_body = jsonencode(local.customer_number_template)

  parameters = {
    InstanceArn = module.connect_us_east_1[0].instance_arn
  }

  tags = local.common_tags

  lifecycle {
    precondition {
      condition = (
        module.connect_us_east_1[0].instance_arn ==
        local.connect_target_instance_arn
      )
      error_message = "CustomerNumberDataTable must be created in the selected V2V Connect instance."
    }

    precondition {
      condition = alltrue([
        for phone_number in keys(local.customer_number_rows) :
        can(regex("^\\+[1-9][0-9]{1,14}$", phone_number))
      ])
      error_message = "system_phonenumber values must use E.164 format."
    }
  }
}


# A separate HR transfer table in the same Terraform file. Phone numbers are
# TEXT and retain the digit-only formatting supplied in the CSV.
locals {
  hr_transfer_csv = <<-CSV
"system_phonenumber","country_hr","hr_contact_transfer"
"18000128353","Colombia","57018005189572"
"18001485151","Dominican Republic","18665486437"
"18002524415","United States","18446634748"
"18004078577","Canada","18553007019"
"18336980332","Jamaica","18552013947"
"18883361367","Trinidad and Tobago","18665462622"
"40190828","Uruguay","5980004135985410"
"50321366339","El Salvador",""
"50769789714","Panama","5078000086"
"576014192633","Nicaragua",""
"8000121897","Costa Rica","5068000320022"
"8000474521","Brazil","5508008920901"
"8000835964","Mexico","528008770373"
"8002661683","Argentina","5408003454866"
"800395181","Chile","56800914883"
"80077559","Peru",""
"8552692014","Guatemala","50224582811"
"8663806011","Puerto Rico","18553075401"
CSV

  hr_transfer_raw_rows = csvdecode(trimspace(local.hr_transfer_csv))
  hr_transfer_columns  = keys(local.hr_transfer_raw_rows[0])

  hr_transfer_rows = {
    for row in local.hr_transfer_raw_rows :
    row.system_phonenumber => row
  }

  hr_transfer_template = {
    AWSTemplateFormatVersion = "2010-09-09"
    Description              = "Amazon Connect HR country and transfer-number data."

    Parameters = {
      InstanceArn = {
        Type = "String"
      }
    }

    Resources = merge(
      {
        HRTransferTable = {
          Type = "AWS::Connect::DataTable"
          Properties = {
            InstanceArn    = { Ref = "InstanceArn" }
            Name           = "BTSGSD-V2V-US-BTSGSD-HR_Transfer"
            Description    = "HR country and transfer number by system phone number."
            Status         = "PUBLISHED"
            TimeZone       = "UTC"
            ValueLockLevel = "NONE"

            Tags = [
              for key, value in merge(local.common_tags, {
                Name = "BTSGSD-V2V-US-BTSGSD-HR_Transfer"
                }) : {
                Key   = key
                Value = value
              }
            ]
          }
        }
      },
      {
        for column in local.hr_transfer_columns :
        "Attribute${replace(column, "_", "")}" => {
          Type = "AWS::Connect::DataTableAttribute"
          Properties = {
            InstanceArn  = { Ref = "InstanceArn" }
            DataTableArn = { "Fn::GetAtt" = ["HRTransferTable", "Arn"] }
            Name         = column
            ValueType    = "TEXT"
            Primary      = column == "system_phonenumber"
          }
        }
      },
      {
        for phone_number, row in local.hr_transfer_rows :
        "Record${phone_number}" => {
          Type = "AWS::Connect::DataTableRecord"
          Properties = {
            InstanceArn  = { Ref = "InstanceArn" }
            DataTableArn = { "Fn::GetAtt" = ["HRTransferTable", "Arn"] }

            DataTableRecord = {
              PrimaryValues = [
                {
                  AttributeId = {
                    "Fn::GetAtt" = [
                      "Attributesystemphonenumber",
                      "AttributeId"
                    ]
                  }
                  AttributeValue = phone_number
                }
              ]

              Values = [
                for column in local.hr_transfer_columns : {
                  AttributeId = {
                    "Fn::GetAtt" = [
                      "Attribute${replace(column, "_", "")}",
                      "AttributeId"
                    ]
                  }
                  AttributeValue = row[column]
                }
                if column != "system_phonenumber"
              ]
            }
          }
        }
      }
    )

    Outputs = {
      DataTableArn = {
        Value = {
          "Fn::GetAtt" = ["HRTransferTable", "Arn"]
        }
      }
    }
  }

  hr_transfer_data_table_id = try(element(
    reverse(split(
      "/",
      aws_cloudformation_stack.hr_transfer_data_table[0].outputs["DataTableArn"]
    )),
    0
  ), null)
}

resource "aws_cloudformation_stack" "hr_transfer_data_table" {
  count    = local.deploy_connect ? 1 : 0
  provider = aws.us_east_1

  name          = "BTSGSD-V2V-US-HRTransferDataTable"
  template_body = jsonencode(local.hr_transfer_template)

  parameters = {
    InstanceArn = module.connect_us_east_1[0].instance_arn
  }

  tags = local.common_tags

  lifecycle {
    precondition {
      condition = (
        module.connect_us_east_1[0].instance_arn ==
        local.connect_target_instance_arn
      )
      error_message = "The HR transfer table must be created in the selected V2V Connect instance."
    }

    precondition {
      condition = alltrue([
        for phone_number in keys(local.hr_transfer_rows) :
        can(regex("^[0-9]+$", phone_number))
      ])
      error_message = "system_phonenumber values must contain digits only."
    }
  }
}


# Preserve the supplied column names, SSML and empty translation cells.
locals {
  survey_template = {
    AWSTemplateFormatVersion = "2010-09-09"
    Description              = "Amazon Connect survey, callback and voicemail messages."
    Parameters = {
      InstanceArn = { Type = "String" }
    }

    Resources = merge(
      {
        SurveyTable = {
          Type = "AWS::Connect::DataTable"
          Properties = {
            InstanceArn    = { Ref = "InstanceArn" }
            Name           = "BTSGSD-V2V-US-Survey-DataTable"
            Description    = "Survey, callback and voicemail configuration by language."
            Status         = "PUBLISHED"
            TimeZone       = "UTC"
            ValueLockLevel = "NONE"
            Tags = [
              for key, value in merge(local.common_tags, { Name = "BTSGSD-V2V-US-Survey-DataTable" }) : {
                Key   = key
                Value = value
              }
            ]
          }
        }
      },
      {
        for column in local.survey_columns : "Attribute${replace(column, "_", "")}" => {
          Type = "AWS::Connect::DataTableAttribute"
          Properties = {
            InstanceArn  = { Ref = "InstanceArn" }
            DataTableArn = { "Fn::GetAtt" = ["SurveyTable", "Arn"] }
            Name         = column
            ValueType    = "TEXT"
            Primary      = column == "Language"
          }
        }
      },
      {
        for language, row in local.survey_rows : "Record${replace(language, "-", "")}" => {
          Type = "AWS::Connect::DataTableRecord"
          Properties = {
            InstanceArn  = { Ref = "InstanceArn" }
            DataTableArn = { "Fn::GetAtt" = ["SurveyTable", "Arn"] }
            DataTableRecord = {
              PrimaryValues = [
                {
                  AttributeId    = { "Fn::GetAtt" = ["AttributeLanguage", "AttributeId"] }
                  AttributeValue = language
                }
              ]
              Values = [
                for column in local.survey_columns : {
                  AttributeId    = { "Fn::GetAtt" = ["Attribute${replace(column, "_", "")}", "AttributeId"] }
                  AttributeValue = row[column]
                }
                if column != "Language"
              ]
            }
          }
        }
      }
    )

    Outputs = {
      DataTableArn = { Value = { "Fn::GetAtt" = ["SurveyTable", "Arn"] } }
    }
  }

  survey_data_table_id = try(element(
    reverse(split("/", aws_cloudformation_stack.survey_data_table[0].outputs["DataTableArn"])),
    0
  ), null)
}

resource "aws_cloudformation_stack" "survey_data_table" {
  count    = local.deploy_connect ? 1 : 0
  provider = aws.us_east_1

  name          = "BTSGSD-V2V-US-SurveyDataTable"
  template_body = jsonencode(local.survey_template)
  parameters = {
    InstanceArn = module.connect_us_east_1[0].instance_arn
  }
  tags = local.common_tags

  lifecycle {
    precondition {
      condition = (
        module.connect_us_east_1[0].instance_arn ==
        local.connect_target_instance_arn
      )
      error_message = "The survey table must be created in the selected V2V Connect instance."
    }

    precondition {
      condition = (
        length(local.survey_columns) == 35 &&
        contains(local.survey_columns, "Language") &&
        contains(local.survey_columns, "VM_instruction_Survey")
      )
      error_message = "The survey CSV must contain the supplied 35 columns, including Language and VM_instruction_Survey."
    }

    precondition {
      condition = (
        toset(keys(local.survey_rows)) ==
        toset(["en-US", "es-MX", "pt-BR"])
      )
      error_message = "The survey CSV must contain exactly the en-US, es-MX and pt-BR language rows."
    }
  }
}


# Countries share system phone numbers, so both columns form the primary key.
# Remove Excel's leading apostrophe from phone cells and retain the supplied digits.
locals {
  veeva_transfer_csv = <<-CSV
"country_LATAM","system_phonenumber","Veeva_contact"
"Argentina","'+548002661683","'+13124799471"
"Argentina","'+576014192633","'+13124799471"
"Bahamas","'+18336980331","'+13124799471"
"Bahamas","'+576014192633","'+13124799471"
"Barbados","'+576014192633","'+13124799471"
"Chile","'+56800395181","'+13124799471"
"Chile","'+576014192633","'+13124799471"
"Colombia","'+5718000128353","'+13124799473"
"Colombia","'+576014192633","'+13124799473"
"Costa Rica","'+576014192633","'+13124799473"
"Curacao","'+576014192633","'+13124799471"
"Dominican Republic","'+18001485151","'+13124799473"
"Dominican Republic","'+576014192633","'+13124799473"
"El Salvador","'+576014192633","'+13124799473"
"Guatemala","'+576014192633","'+13124799473"
"Honduras","'+576014192633","'+13124799473"
"Jamaica","'+1833698332","'+13124799471"
"Jamaica","'+576014192633","'+13124799471"
"Mexico","'+528000835964","'+13124799473"
"Nicaragua","'+576014192633","'+13124799473"
"Panama","'+50769789714","'+13124799473"
"Peru","'+5180077559","'+13124799473"
"Puerto Rico","'+18663806011","'+13124799471"
"Trinidad and Tobago","'+576014192633","'+13124799471"
"Uruguay","'+576014192633","'+13124799473"
"Venezuela","'+576014192633","'+13124799471"
CSV

  veeva_transfer_raw_rows        = csvdecode(trimspace(local.veeva_transfer_csv))
  veeva_transfer_columns         = keys(local.veeva_transfer_raw_rows[0])
  veeva_transfer_primary_columns = ["country_LATAM", "system_phonenumber"]
  veeva_transfer_rows = {
    for row in local.veeva_transfer_raw_rows :
    jsonencode([row.country_LATAM, trimprefix(trimspace(row.system_phonenumber), "'")]) => {
      for column, value in row : column => (
        contains(["system_phonenumber", "Veeva_contact"], column)
        ? trimprefix(trimspace(value), "'")
        : value
      )
    }
  }

  veeva_transfer_template = {
    AWSTemplateFormatVersion = "2010-09-09"
    Description              = "Amazon Connect Veeva transfer contacts by country and system phone number."
    Parameters = {
      InstanceArn = { Type = "String" }
    }

    Resources = merge(
      {
        VeevaTransferTable = {
          Type = "AWS::Connect::DataTable"
          Properties = {
            InstanceArn    = { Ref = "InstanceArn" }
            Name           = "BTSGSD-V2V-US-BTSGSD-Veeva_Transfer"
            Description    = "Veeva transfer contact by LATAM country and system phone number."
            Status         = "PUBLISHED"
            TimeZone       = "UTC"
            ValueLockLevel = "NONE"
            Tags = [
              for key, value in merge(local.common_tags, { Name = "BTSGSD-V2V-US-BTSGSD-Veeva_Transfer" }) : {
                Key   = key
                Value = value
              }
            ]
          }
        }
      },
      {
        for column in local.veeva_transfer_columns : "Attribute${replace(column, "_", "")}" => {
          Type = "AWS::Connect::DataTableAttribute"
          Properties = {
            InstanceArn  = { Ref = "InstanceArn" }
            DataTableArn = { "Fn::GetAtt" = ["VeevaTransferTable", "Arn"] }
            Name         = column
            ValueType    = "TEXT"
            Primary      = contains(local.veeva_transfer_primary_columns, column)
          }
        }
      },
      {
        for row in values(local.veeva_transfer_rows) :
        "Record${replace(row.country_LATAM, "/[^A-Za-z0-9]/", "")}${replace(row.system_phonenumber, "+", "")}" => {
          Type = "AWS::Connect::DataTableRecord"
          Properties = {
            InstanceArn  = { Ref = "InstanceArn" }
            DataTableArn = { "Fn::GetAtt" = ["VeevaTransferTable", "Arn"] }
            DataTableRecord = {
              PrimaryValues = [
                for column in local.veeva_transfer_primary_columns : {
                  AttributeId    = { "Fn::GetAtt" = ["Attribute${replace(column, "_", "")}", "AttributeId"] }
                  AttributeValue = row[column]
                }
              ]
              Values = [
                for column in local.veeva_transfer_columns : {
                  AttributeId    = { "Fn::GetAtt" = ["Attribute${replace(column, "_", "")}", "AttributeId"] }
                  AttributeValue = row[column]
                }
                if !contains(local.veeva_transfer_primary_columns, column)
              ]
            }
          }
        }
      }
    )

    Outputs = {
      DataTableArn = { Value = { "Fn::GetAtt" = ["VeevaTransferTable", "Arn"] } }
    }
  }

  veeva_transfer_data_table_id = try(element(
    reverse(split("/", aws_cloudformation_stack.veeva_transfer_data_table[0].outputs["DataTableArn"])),
    0
  ), null)
}

resource "aws_cloudformation_stack" "veeva_transfer_data_table" {
  count    = local.deploy_connect ? 1 : 0
  provider = aws.us_east_1

  name          = "BTSGSD-V2V-US-VeevaTransferDataTable"
  template_body = jsonencode(local.veeva_transfer_template)
  parameters = {
    InstanceArn = module.connect_us_east_1[0].instance_arn
  }
  tags = local.common_tags

  lifecycle {
    precondition {
      condition = (
        module.connect_us_east_1[0].instance_arn ==
        local.connect_target_instance_arn
      )
      error_message = "The Veeva transfer table must be created in the selected V2V Connect instance."
    }

    precondition {
      condition = alltrue([
        for row in values(local.veeva_transfer_rows) :
        trimspace(row.country_LATAM) != "" &&
        can(regex("^\\+[1-9][0-9]{1,14}$", row.system_phonenumber)) &&
        can(regex("^\\+[1-9][0-9]{1,14}$", row.Veeva_contact))
      ])
      error_message = "Veeva rows require a country and E.164 system/transfer phone numbers."
    }
  }
}


# An empty blocker message is intentional; retain it as an empty TEXT value.
locals {
  top_level_blocker_csv = <<-CSV
"system_phonenumber","toplevelblocker_message"
"'+18335162999",""
CSV

  top_level_blocker_raw_rows = csvdecode(trimspace(local.top_level_blocker_csv))
  top_level_blocker_columns  = keys(local.top_level_blocker_raw_rows[0])
  top_level_blocker_rows = {
    for row in local.top_level_blocker_raw_rows :
    trimprefix(trimspace(row.system_phonenumber), "'") => merge(row, {
      system_phonenumber = trimprefix(trimspace(row.system_phonenumber), "'")
    })
  }

  top_level_blocker_template = {
    AWSTemplateFormatVersion = "2010-09-09"
    Description              = "Amazon Connect top-level blocker messages by dialed phone number."
    Parameters = {
      InstanceArn = { Type = "String" }
    }

    Resources = merge(
      {
        TopLevelBlockerTable = {
          Type = "AWS::Connect::DataTable"
          Properties = {
            InstanceArn    = { Ref = "InstanceArn" }
            Name           = "BTSGSD-V2V-US-TopLevelBlockerMessage"
            Description    = "Top-level blocker message by system phone number."
            Status         = "PUBLISHED"
            TimeZone       = "UTC"
            ValueLockLevel = "NONE"
            Tags = [
              for key, value in merge(local.common_tags, { Name = "BTSGSD-V2V-US-TopLevelBlockerMessage" }) : {
                Key   = key
                Value = value
              }
            ]
          }
        }
      },
      {
        for column in local.top_level_blocker_columns : "Attribute${replace(column, "_", "")}" => {
          Type = "AWS::Connect::DataTableAttribute"
          Properties = {
            InstanceArn  = { Ref = "InstanceArn" }
            DataTableArn = { "Fn::GetAtt" = ["TopLevelBlockerTable", "Arn"] }
            Name         = column
            ValueType    = "TEXT"
            Primary      = column == "system_phonenumber"
          }
        }
      },
      {
        for phone_number, row in local.top_level_blocker_rows : "Record${replace(phone_number, "+", "")}" => {
          Type = "AWS::Connect::DataTableRecord"
          Properties = {
            InstanceArn  = { Ref = "InstanceArn" }
            DataTableArn = { "Fn::GetAtt" = ["TopLevelBlockerTable", "Arn"] }
            DataTableRecord = {
              PrimaryValues = [
                {
                  AttributeId    = { "Fn::GetAtt" = ["Attributesystemphonenumber", "AttributeId"] }
                  AttributeValue = phone_number
                }
              ]
              Values = [
                for column in local.top_level_blocker_columns : {
                  AttributeId    = { "Fn::GetAtt" = ["Attribute${replace(column, "_", "")}", "AttributeId"] }
                  AttributeValue = row[column]
                }
                if column != "system_phonenumber"
              ]
            }
          }
        }
      }
    )

    Outputs = {
      DataTableArn = { Value = { "Fn::GetAtt" = ["TopLevelBlockerTable", "Arn"] } }
    }
  }

  top_level_blocker_data_table_id = try(element(
    reverse(split("/", aws_cloudformation_stack.top_level_blocker_data_table[0].outputs["DataTableArn"])),
    0
  ), null)
}

resource "aws_cloudformation_stack" "top_level_blocker_data_table" {
  count    = local.deploy_connect ? 1 : 0
  provider = aws.us_east_1

  name          = "BTSGSD-V2V-US-TopLevelBlockerMessage"
  template_body = jsonencode(local.top_level_blocker_template)
  parameters = {
    InstanceArn = module.connect_us_east_1[0].instance_arn
  }
  tags = local.common_tags

  lifecycle {
    precondition {
      condition = (
        module.connect_us_east_1[0].instance_arn ==
        local.connect_target_instance_arn
      )
      error_message = "TopLevelBlockerMessage must be created in the selected V2V Connect instance."
    }

    precondition {
      condition = alltrue([
        for phone_number in keys(local.top_level_blocker_rows) :
        can(regex("^\\+[1-9][0-9]{1,14}$", phone_number))
      ])
      error_message = "Top-level blocker system_phonenumber values must use E.164 format."
    }
  }
}


# Composite primary key: country + system_phonenumber.
# Flow lookups must supply both attributes because phone numbers repeat.
# All columns remain TEXT; strip Excel's leading apostrophe from phone numbers.
locals {
  bts_gsd_customer_number_csv = <<-CSV
"country","system_phonenumber","amazon_speaking_engine","amazon_speaking_style","amazon_voice","hr_contact","language_code","language_name","medcom_contact","region","veeva_contact"
"","'+12","neural","conversational","Aditi","","hi-IN","Hindi","","",""
"Argentina","'+548002661683","neural","conversational","Katie","'+5408003454866","es-MX","Spanish","'+13152949458","LATAM","'+13124799471"
"Argentina","'+576014192633","neural","conversational","Katie","'+5408003454866","es-MX","Spanish","'+13152949458","LATAM","'+13124799471"
"Bahamas","'+18336980331","neural","conversational","Katie","","es-MX","Spanish","'+13152949458","LATAM","'+13124799471"
"Bahamas","'+576014192633","neural","conversational","Katie","","es-MX","Spanish","'+13152949458","LATAM","'+13124799471"
"Barbados","'+576014192633","neural","conversational","Katie","","es-MX","Spanish","'+13152949458","LATAM","'+13124799471"
"Canada","'+18004078577","neural","conversational","Katie","'+18553007019","en-US","English","","NORAM",""
"Chile","'+56800395181","neural","conversational","Katie","'+56800914883","es-MX","Spanish","'+13152949458","LATAM","'+13124799471"
"Chile","'+576014192633","neural","conversational","Katie","'+56800914883","es-MX","Spanish","'+13152949458","LATAM","'+13124799471"
"Colombia","'+5718000128353","neural","conversational","Katie","'+57018005189572","es-MX","Spanish","'+13152949458","LATAM","'+13124799473"
"Colombia","'+576014192633","neural","conversational","Katie","'+57018005189572","es-MX","Spanish","'+13152949458","LATAM","'+13124799473"
"Costa Rica","'+576014192633","neural","conversational","Katie","'+5068000320022","es-MX","Spanish","'+13152949458","LATAM","'+13124799473"
"Curacao","'+576014192633","neural","conversational","Katie","","es-MX","Spanish","'+13152949458","LATAM","'+13124799471"
"Dominican Republic","'+18001485151","neural","conversational","Katie","'+18665486437","es-MX","Spanish","'+13152949458","LATAM","'+13124799473"
"Dominican Republic","'+576014192633","neural","conversational","Katie","'+18665486437","es-MX","Spanish","'+13152949458","LATAM","'+13124799473"
"El Salvador","'+576014192633","neural","conversational","Katie","","es-MX","Spanish","'+13152949458","LATAM","'+13124799473"
"Guatemala","'+576014192633","neural","conversational","Katie","'+50224582811","es-MX","Spanish","'+13152949458","LATAM","'+13124799473"
"Honduras","'+576014192633","neural","conversational","Katie","","es-MX","Spanish","'+13152949458","LATAM","'+13124799473"
"Jamaica","'+1833698332","neural","conversational","Katie","'+18552013947","es-MX","Spanish","'+13152949458","LATAM","'+13124799471"
"Jamaica","'+576014192633","neural","conversational","Katie","'+18552013947","es-MX","Spanish","'+13152949458","LATAM","'+13124799471"
"Mexico","'+528000835964","neural","conversational","Katie","'+528008770373","es-MX","Spanish","'+13152949458","LATAM","'+13124799473"
"Nicaragua","'+576014192633","neural","conversational","Katie","","es-MX","Spanish","'+13152949458","LATAM","'+13124799473"
"Panama","'+50769789714","neural","conversational","Katie","'+5078000086","es-MX","Spanish","'+13152949458","LATAM","'+13124799473"
"Peru","'+5180077559","neural","conversational","Katie","","es-MX","Spanish","'+13152949458","LATAM","'+13124799473"
"Puerto Rico","'+18663806011","neural","conversational","Katie","'+18553075401","es-MX","Spanish","'+13152949458","LATAM","'+13124799471"
"Trinidad and Tobago","'+576014192633","neural","conversational","Katie","'+18665462622","es-MX","Spanish","'+13152949458","LATAM","'+13124799471"
"United States","'+18335162999","neural","conversational","Katie","'+18446634748","en-US","English","'+13152949458","NORAM","'+13124799473"
"Uruguay","'+576014192633","neural","conversational","Katie","'+5980004135985411","es-MX","Spanish","'+13152949458","LATAM","'+13124799473"
"USA","'+18002524415","neural","conversational","Katie","'+18446634748","en-US","English","","NORAM",""
"Venezuela","'+576014192633","neural","conversational","Katie","","es-MX","Spanish","'+13152949458","LATAM","'+13124799471"
CSV

  bts_gsd_customer_number_raw_rows = csvdecode(
    trimspace(local.bts_gsd_customer_number_csv)
  )

  bts_gsd_customer_number_columns = keys(
    local.bts_gsd_customer_number_raw_rows[0]
  )

  bts_gsd_customer_number_primary_columns = [
    "country",
    "system_phonenumber",
  ]

  bts_gsd_customer_number_rows = {
    for row in local.bts_gsd_customer_number_raw_rows :
    jsonencode([
      row.country,
      trimprefix(trimspace(row.system_phonenumber), "'"),
      ]) => {
      for column, value in row :
      column => (
        contains(
          ["system_phonenumber", "hr_contact", "medcom_contact", "veeva_contact"],
          column
        )
        ? trimprefix(trimspace(value), "'")
        : value
      )
    }
  }

  bts_gsd_customer_number_template = {
    AWSTemplateFormatVersion = "2010-09-09"
    Description              = "BTSGSD-CustomerNumber routing configuration."

    Parameters = {
      InstanceArn = {
        Type = "String"
      }
    }

    Resources = merge(
      {
        CustomerNumberTable = {
          Type = "AWS::Connect::DataTable"
          Properties = {
            InstanceArn    = { Ref = "InstanceArn" }
            Name           = "BTSGSD-V2V-US-BTSGSD-CustomerNumber"
            Description    = "Routing configuration by country and system phone number."
            Status         = "PUBLISHED"
            TimeZone       = "UTC"
            ValueLockLevel = "NONE"

            Tags = [
              for key, value in merge(local.common_tags, {
                Name = "BTSGSD-V2V-US-BTSGSD-CustomerNumber"
                }) : {
                Key   = key
                Value = value
              }
            ]
          }
        }
      },
      {
        for column in local.bts_gsd_customer_number_columns :
        "Attribute${replace(column, "_", "")}" => {
          Type = "AWS::Connect::DataTableAttribute"
          Properties = {
            InstanceArn  = { Ref = "InstanceArn" }
            DataTableArn = { "Fn::GetAtt" = ["CustomerNumberTable", "Arn"] }
            Name         = column
            ValueType    = "TEXT"
            Primary      = contains(local.bts_gsd_customer_number_primary_columns, column)
          }
        }
      },
      {
        for row_key, row in local.bts_gsd_customer_number_rows :
        "Record${md5(row_key)}" => {
          Type = "AWS::Connect::DataTableRecord"
          Properties = {
            InstanceArn  = { Ref = "InstanceArn" }
            DataTableArn = { "Fn::GetAtt" = ["CustomerNumberTable", "Arn"] }

            DataTableRecord = {
              PrimaryValues = [
                for column in local.bts_gsd_customer_number_primary_columns : {
                  AttributeId = {
                    "Fn::GetAtt" = [
                      "Attribute${replace(column, "_", "")}",
                      "AttributeId",
                    ]
                  }
                  AttributeValue = row[column]
                }
              ]

              Values = [
                for column in local.bts_gsd_customer_number_columns : {
                  AttributeId = {
                    "Fn::GetAtt" = [
                      "Attribute${replace(column, "_", "")}",
                      "AttributeId",
                    ]
                  }
                  AttributeValue = row[column]
                }
                if !contains(local.bts_gsd_customer_number_primary_columns, column)
              ]
            }
          }
        }
      }
    )

    Outputs = {
      DataTableArn = {
        Value = {
          "Fn::GetAtt" = ["CustomerNumberTable", "Arn"]
        }
      }
    }
  }
}

resource "aws_cloudformation_stack" "bts_gsd_customer_number_data_table" {
  count    = local.deploy_connect ? 1 : 0
  provider = aws.us_east_1

  name          = "BTSGSD-V2V-US-BTS-GSD-CustomerNumber"
  template_body = jsonencode(local.bts_gsd_customer_number_template)

  parameters = {
    InstanceArn = module.connect_us_east_1[0].instance_arn
  }

  tags = local.common_tags

  lifecycle {
    precondition {
      condition = (
        module.connect_us_east_1[0].instance_arn ==
        local.connect_target_instance_arn
      )
      error_message = "BTSGSD-CustomerNumber must use the selected V2V Connect instance."
    }
  }
}

# Configuration consolidated from survey_flow.tf
data "external" "survey_flow_dependencies" {
  count = local.deploy_connect ? 1 : 0

  program = [
    var.connect_flow_python_executable,
    "${path.module}/../../v2v_modules/connect/scripts/resolve_customer_queue_dependencies.py"
  ]

  query = {
    region         = "us-east-1"
    instance_id    = module.connect_us_east_1[0].instance_id
    instance_arn   = module.connect_us_east_1[0].instance_arn
    name_overrides = jsonencode(var.connect_customer_queue_dependency_names)

    content = replace(
      replace(
        replace(
          file("${path.module}/metadata/contact-flows/BTSGSD-AIAgent-SurveyFlow.json"),
          "41573eb0-ae92-4b8a-bbe2-e4a32fb84801",
          local.survey_data_table_id
        ),
        "arn:aws:lambda:us-east-1:518902362956:function:UpdateSessionAttributes",
        module.BTSGSD-V2V-US-UpdateSessionAttributes[0].lambda_arn
      ),
      "sureveyFlow_1",
      "VM_instruction_Survey"
    )
  }
}

resource "aws_connect_contact_flow" "survey" {
  count    = local.deploy_connect ? 1 : 0
  provider = aws.us_east_1

  instance_id = module.connect_us_east_1[0].instance_id
  name        = "BTSGSD-V2V-US-AIAgent-SurveyFlow"
  description = "AI agent customer satisfaction survey."
  type        = "CONTACT_FLOW"
  content     = data.external.survey_flow_dependencies[0].result.content

  tags = merge(local.common_tags, {
    Name = "BTSGSD-V2V-US-AIAgent-SurveyFlow"
  })

  depends_on = [module.BTSGSD-V2V-US-UpdateSessionAttributes]

  lifecycle {
    precondition {
      condition     = module.connect_us_east_1[0].instance_id == local.connect_target_instance_id
      error_message = "Deploy the survey only to the selected V2V Connect instance."
    }
  }
}

# Adding new modules for Connect resources (users, queues, prompts etc)

module "connect_resources" {
  count  = local.deploy_connect_resources ? 1 : 0
  source = "../../v2v_modules/connect-resources"

  providers = {
    aws   = aws.us_east_1
    awscc = awscc.us_east_1
  }

  instance_id  = data.aws_connect_instance.target[0].id
  instance_arn = data.aws_connect_instance.target[0].arn

  hours_of_operation_id  = var.connect_resources_dependencies.hours_of_operation_id
  connect_queue_queue_id = var.connect_resources_dependencies.main_queue_id
  outbound_flow_id       = var.connect_resources_dependencies.outbound_flow_id
  quick_connect_flow_id  = var.connect_resources_dependencies.quick_connect_flow_id

  outbound_caller_id_number_id = local.resolved_outbound_phone_number_id
  moh_30sec_prompt_s3_uri      = var.moh_30sec_prompt_s3_uri
  tags                         = local.common_tags

  # Match the module's existing TASK/VOICE routing configuration.
  blended_routing_profile_default_outbound_queue = "us_out"
  blended_routing_profile_media_concurrencies = [
    { channel = "TASK", concurrency = 1 },
    { channel = "VOICE", concurrency = 1 },
  ]
}

# signing_profile

module "signing_profile" {
  count = local.deploy_code_signing && var.enable_signing_profile ? 1 : 0

  source = "../../v2v_modules/signing_profile"

  providers = {
    aws = aws.us_east_1
  }

  profile_name = var.signing_profile_name
  common_tags  = local.common_tags
}

# code_signing_config

module "code_signing_config" {
  count = local.deploy_code_signing && var.enable_code_signing_config && var.enable_signing_profile ? 1 : 0

  source = "../../v2v_modules/code_signing_config"

  providers = {
    aws = aws.us_east_1
  }

  signing_profile_version_arn = module.signing_profile[0].signing_profile_version_arn
  common_tags                 = local.common_tags
}
