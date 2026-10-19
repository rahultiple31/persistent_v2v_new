locals {
  common_tags = merge(var.common_tags, {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
    Platform    = "Amazon Connect V2V Translation"
    Application = var.app_name
    Network     = "No Custom VPC"
  })

  enabled_module_set = toset([for module_name in var.enabled_modules : lower(module_name)])
  deploy_connect     = contains(local.enabled_module_set, "connect")
  deploy_lambda      = contains(local.enabled_module_set, "lambda")
  deploy_proxy       = contains(local.enabled_module_set, "proxy") && local.translation_mode == "proxy"
  deploy_v2v         = contains(local.enabled_module_set, "v2v")
}

locals {
  imported_flow_directory = "${path.module}/metadata/contact-flows"

  # Display names are independent of the JSON export filenames.
  # Flow types match the Metadata.type values in the complete exports.
  imported_flow_definitions = {
    fieldforce = {
      filename = "AbbVie_Fieldforce_Flow.json"
      name     = "stdgsd_Fieldforce_Flow"
      type     = "CONTACT_FLOW"
    }

    customer_queue = {
      filename = "BTSGSD_Abbvie_CustomerQueueFlow.json"
      name     = "btsgsd_Abbvie_CustomerQueueFlow"
      type     = "CUSTOMER_QUEUE"
    }

    agent_transfer = {
      filename = "BTSGSD-AgentToAgentTransferFlow.json"
      name     = "btsgsd-AgentToAgentTransferFlow"
      type     = "AGENT_TRANSFER"
    }

    main_inbound = {
      filename = "BTSGSD-Main-IB-Flow.json"
      name     = "btsgsd-Main-IB-Flow"
      type     = "CONTACT_FLOW"
    }

    outbound_whisper = {
      filename = "BTSGSD-OutboundWhisperFlow.json"
      name     = "btsgsd-OutboundWhisperFlow"
      type     = "OUTBOUND_WHISPER"
    }

    transfer_customer_queue = {
      filename = "BTSGSD-Transfer-To-Agent-CustomerQueueFlow.json"
      name     = "btsgsd-Transfer-To-Agent-CustomerQueueFlow"
      type     = "CUSTOMER_QUEUE"
    }

    voicemail = {
      filename = "BTSGSD-VoicemailFlow.json"
      name     = "btsgsd-VoicemailFlow"
      type     = "CONTACT_FLOW"
    }

    hr = {
      filename = "AbbVie_HR.json"
      name     = "btsgsd_HR"
      type     = "CONTACT_FLOW"
    }
  }

  # Stack outputs bind table lookups and defer dependency lookup until creation.
  rendered_imported_contact_flows = local.deploy_connect ? {
    for key, flow in local.imported_flow_definitions : key => {
      name = flow.name
      type = flow.type
      content = contains(["customer_queue", "main_inbound"], key) ? replace(
        key == "main_inbound" ? replace(
          file("${local.imported_flow_directory}/${flow.filename}"),
          "e0917ae9-956c-4e02-b73f-43150201aa7f",
          local.top_level_blocker_data_table_id
        ) : file("${local.imported_flow_directory}/${flow.filename}"),
        "41573eb0-ae92-4b8a-bbe2-e4a32fb84801",
        local.survey_data_table_id
      ) : file("${local.imported_flow_directory}/${flow.filename}")
    }
  } : {}
}

module "connect_us_east_1" {
  count  = local.deploy_connect ? 1 : 0
  source = "../../modules/connect"

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
  expected_instance_arn = "arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d"
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
  customer_number_data_table_id     = local.customer_number_data_table_id
}

module "connect_views" {
  count  = local.deploy_connect ? 1 : 0
  source = "../../modules/connect_views"

  providers = {
    awscc = awscc.us_east_1
  }

  connect_instance_arn = module.connect_us_east_1[0].instance_arn
  view_name            = "Customer Details"
  view_template        = file("${path.module}/metadata/views/customer_details.json")
  common_tags          = local.common_tags
}

module "abbvie_views" {
  count  = local.deploy_connect ? 1 : 0
  source = "../../modules/abbvie_views"

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
  source = "../../modules/ai_agent_tools"

  namespace = "gateway-quick-start-dev-tfkjeu6nxc"

  # Exact gateway names from the current agentcore_gateway code.
  tool_names = [
    "nexthink-handoff___handoff",
    "snow-interaction___Interaction__Interaction",
    "snow-userlookup___UserLookUp___UserLookUp",
  ]
}

module "btsgsd_support_agent" {
  count  = local.dev_support_ai_enabled ? 1 : 0
  source = "../../modules/connect_ai_agent"

  providers = {
    aws = aws.us_east_1
  }

  agent_name         = "btsgsd-SupportAgent"
  prompt_name        = "btsgsd-SupportAgent-prompt"
  stack_name         = "btsgsd-SupportAgent-dev"
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
  source = "../../modules/connect_ai_agent"

  providers = {
    aws = aws.us_east_1
  }

  agent_name        = "btsgsd-ai-survey-agent"
  prompt_name       = "btsgsd-ai-survey-prompt"
  stack_name        = "btsgsd-ai-survey-agent-dev"
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

module "lambda_us_east_1" {
  count  = local.deploy_lambda ? 1 : 0
  source = "../../modules/lambda"

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
  count  = contains(local.enabled_module_set, "lambda-ctr-survey") ? 1 : 0
  source = "../../modules/lambda-ctr-survey"

  providers = {
    aws = aws.us_east_1
  }

  source_file            = abspath("${path.module}/metadata/lambda-ctr/lambda_function_ctr_.py")
  handler                = "lambda_function_ctr_.lambda_handler"
  connect_instance_alias = var.connect_instance_alias
  common_tags            = local.common_tags
}

module "lambda-connect-daily-ctr-export" {
  count  = contains(local.enabled_module_set, "lambda-connect-daily-ctr-export") ? 1 : 0
  source = "../../modules/lambda-connect-daily-ctr-export"

  providers = {
    aws = aws.us_east_1
  }

  source_file            = abspath("${path.module}/metadata/lambda-ctr/lambda_function_ctr_export.py")
  connect_instance_alias = var.connect_instance_alias
  common_tags            = local.common_tags
}

module "lambda-ctr-raw" {
  count  = contains(local.enabled_module_set, "lambda-ctr-raw") ? 1 : 0
  source = "../../modules/lambda-ctr-raw"

  providers = {
    aws = aws.us_east_1
  }

  source_file            = abspath("${path.module}/metadata/lambda-ctr/lambda_function_ctr_raw.py")
  connect_instance_alias = var.connect_instance_alias
  common_tags            = local.common_tags
}

module "lambda-snow-btsgsd-dev" {
  count  = contains(local.enabled_module_set, "lambda-snow-btsgsd-dev") ? 1 : 0
  source = "../../modules/lambda-snow-btsgsd-dev"

  providers = {
    aws      = aws.us_east_1
    external = external
  }

  function_name         = "SNOW_btsgsd-dev"
  environment_variables = var.snow_lambda_environment_variables
  python_executable     = var.snow_lambda_python_executable
  reserved_concurrency  = var.snow_lambda_reserved_concurrency
  common_tags           = local.common_tags
}

module "iam-ctr" {
  count  = contains(local.enabled_module_set, "iam-ctr") ? 1 : 0
  source = "../../modules/iam-ctr"

  providers = {
    aws = aws.us_east_1
  }

  policy_name   = "btsgsd-dev-us-east-1-ctr-reporting-policy"
  s3_object_arn = "arn:aws:s3:::btsgsd-dev-us-east-1-connect-reporting-bucket/connect/daily-interactions/*"

  role_names = [
    "btsgsd-dev-us-east-1-CTR-Survey-lambda-role",
    "btsgsd-dev-us-east-1-connect-daily-ctr-export-lambda-role",
    "btsgsd-dev-us-east-1-CTR-Raw-lambda-role"
  ]
}

module "s3_connect_reporting" {
  count  = contains(local.enabled_module_set, "s3_connect_reporting") ? 1 : 0
  source = "../../modules/s3_connect_reporting"

  providers = {
    aws = aws.us_east_1
  }

  bucket_name = "btsgsd-dev-us-east-1-connect-reporting-bucket"
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
  name_prefix = lower(replace(coalesce(var.resource_name_prefix, "${var.project_name}-${var.environment}-${var.app_name}"), "_", "-"))

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
    novaSonicModelId          = var.proxy_bedrock_model_id
    translationEnabled        = tostring(local.v2v_translation_enabled)
    proxyEnabled              = tostring(local.proxy_integration_active)
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
    novaSonicModelId      = var.proxy_bedrock_model_id
    translationEnabled    = tostring(local.v2v_translation_enabled)
    ssoEnabled            = tostring(var.sso_enabled)
    ssoProviderName       = var.sso_provider_name
    proxyAllowedGroups    = length(var.proxy_allowed_groups) == 0 ? "not-defined" : join(",", var.proxy_allowed_groups)
    cspEnforced           = tostring(var.csp_enforced)
  }
}

module "s3_v2v" {
  count  = local.deploy_v2v ? 1 : 0
  source = "../../modules/s3_v2v"

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
  source = "../../modules/cloudfront_v2v"

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
  proxy_enabled                   = local.proxy_integration_active
  proxy_alb_arn                   = try(local.proxy_state.internal_alb_arn, "")
  proxy_alb_dns_name              = try(local.proxy_state.internal_alb_dns_name, "")
  translation_mode                = local.v2v_translation_mode
  cognito_domain_url              = "https://${var.cognito_domain_prefix}.auth.us-east-1.amazoncognito.com"
  connect_instance_url            = var.connect_instance_url
  connect_instance_region         = var.connect_instance_region
  csp_enforced                    = var.csp_enforced
  common_tags                     = local.common_tags
}

module "cognito_v2v" {
  count  = local.deploy_v2v ? 1 : 0
  source = "../../modules/cognito_v2v"

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
  source = "../../modules/iam_v2v"

  providers = {
    aws = aws.us_east_1
  }

  name_prefix       = local.name_prefix
  identity_pool_id  = try(module.cognito_v2v[0].identity_pool_id, "")
  translation_mode  = local.v2v_translation_mode
  bedrock_region    = var.bedrock_region
  bedrock_model_id  = var.proxy_bedrock_model_id
  transcribe_region = local.transcribe_region
  translate_region  = local.translate_region
  polly_region      = local.polly_region
  common_tags       = local.common_tags
}

module "ssm_v2v" {
  count  = local.deploy_v2v ? 1 : 0
  source = "../../modules/ssm_v2v"

  providers = {
    aws = aws.us_east_1
  }

  ssm_hierarchy = var.ssm_hierarchy
  parameters    = local.ssm_parameters
  common_tags   = local.common_tags
}

module "lambda-servicenow-interaction" {
  count  = contains(local.enabled_module_set, "lambda-servicenow-interaction") ? 1 : 0
  source = "../../modules/lambda-servicenow-interaction"

  providers = {
    aws      = aws.us_east_1
    external = external
  }

  common_tags           = local.common_tags
  environment_variables = var.servicenow_interaction_environment_variables
  python_executable     = var.servicenow_interaction_python_executable
  reserved_concurrency  = var.servicenow_interaction_reserved_concurrency
}

module "lambda-nextthink-handoff" {
  count  = contains(local.enabled_module_set, "lambda-nextthink-handoff") ? 1 : 0
  source = "../../modules/lambda-nextthink-handoff"

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
  source = "../../modules/agentcore_gateway"

  providers = {
    aws = aws.us_east_1
  }

  stack_name             = "btsgsd-dev-AgentCore-DefaultGateway"
  gateway_name           = "gateway-quick-start-dev"
  role_name              = "btsgsd-dev-agentcore-default-gateway-role"
  lambda_arn             = "arn:aws:lambda:us-east-1:518902362956:function:SNOW_btsgsd-dev"
  interaction_lambda_arn = "arn:aws:lambda:us-east-1:518902362956:function:ServiceNow_Interaction_btsgsd-dev"
  nexthink_lambda_arn    = "arn:aws:lambda:us-east-1:518902362956:function:Nextthink_Handoff_btsgsd-dev"
  connect_url            = "https://btsgsd-dev-us-east-1.my.connect.aws"
  gateway_id_audience    = var.agentcore_gateway_id_audience
  common_tags            = local.common_tags
}

module "connect_Integrations" {
  count = (
    local.deploy_connect &&
    var.agentcore_gateway_enabled &&
    var.connect_integrations_enabled
  ) ? 1 : 0

  source = "../../modules/connect_Integrations"

  providers = {
    aws = aws.us_east_1
  }

  stack_name           = "btsgsd-dev-Connect-SNOW-MCP-Integration"
  display_name         = "btsgsd_SNOW"
  connect_instance_arn = "arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d"
  gateway_id           = module.agentcore_gateway[0].deployment.id
  gateway_url          = module.agentcore_gateway[0].deployment.url
  common_tags          = local.common_tags
}

module "secrets_manager" {
  count  = contains(local.enabled_module_set, "secrets_manager") ? 1 : 0
  source = "../../modules/secrets_manager"

  providers = {
    aws = aws.us_east_1
  }

  secrets     = var.secrets_manager_secrets
  common_tags = local.common_tags
}

# Deploys with the btsgsd-intent-kb selection.
module "s3_intent_kb" {
  count  = contains(local.enabled_module_set, "btsgsd-intent-kb") ? 1 : 0
  source = "../../modules/s3_intent_kb"

  providers = {
    aws = aws.us_east_1
  }

  bucket_name = "btsgsd-intent-kb"
}

# Deploys with the lex_bot selection.
# Creates a blank DRAFT bot; no custom intents or published versions.
module "lex_bot" {
  count  = contains(local.enabled_module_set, "lex_bot") ? 1 : 0
  source = "../../modules/lex_bot"

  providers = {
    aws = aws.us_east_1
  }

  bot_name = "btsgsd-IT-Support_Agent-dev"
}

# Invoke this Lambda after the Connect assistant block in the contact flow.
module "UpdateSessionAttributes-dev" {
  count  = local.deploy_connect ? 1 : 0
  source = "../../modules/UpdateSessionAttributes-dev"

  providers = {
    aws = aws.us_east_1
  }

  function_name        = "UpdateSessionAttributes-dev"
  zip_path             = "${path.module}/metadata/scr_lambda/lambda_function.zip"
  connect_instance_arn = module.connect_us_east_1[0].instance_arn
  assistant_id         = local.dev_ai_assistant_id
  common_tags          = local.common_tags
}

# Deploys with the connect selection.
module "silence_guard-dev" {
  count  = local.deploy_connect ? 1 : 0
  source = "../../modules/silence_guard-dev"

  providers = {
    aws = aws.us_east_1
  }

  connect_instance_arn = module.connect_us_east_1[0].instance_arn
  common_tags          = local.common_tags
}

# Deploys with the existing Connect selection.
module "conversion_of_queue_metrics" {
  count  = local.deploy_connect ? 1 : 0
  source = "../../modules/conversionOfQueueMetrics-dev"

  providers = {
    aws = aws.us_east_1
  }

  function_name  = "conversionOfQueueMetrics-dev"
  iam_role_name  = "conversionOfQueueMetrics-role-ox32eazp"
  log_group_name = "/aws/lambda/conversionOfQueueMetrics-dev"
  zip_path       = "${path.module}/metadata/conversionOfQueueMetrics-dev_lambda/lambda_function.zip"

  environment_variables = {
    TableName   = "queueInfo"
    LOG_LEVEL   = "DEBUG"
    TTL_SECONDS = "86400"
  }

  common_tags = local.common_tags
}

# Deploys with the existing Connect selection.
module "lex_queueflow_callback" {
  count  = local.deploy_connect ? 1 : 0
  source = "../../modules/BTSGSD-lex-QueueFlow-Callback-dev"

  providers = {
    aws = aws.us_east_1
  }

  function_name  = "BTSGSD-lex-QueueFlow-Callback-dev"
  iam_role_name  = "BTSGSD-lex-QueueFlow-Callback-role-i0v0kqis"
  log_group_name = "/aws/lambda/BTSGSD-lex-QueueFlow-Callback-dev"

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
  count  = local.deploy_connect ? 1 : 0
  source = "../../modules/BTSGSD-lex-yesNo-dev"

  providers = {
    aws = aws.us_east_1
  }

  function_name  = "BTSGSD-lex-yesNo-dev"
  iam_role_name  = "BTSGSD-lex-yesNo-role-ow5vzdof"
  log_group_name = "/aws/lambda/BTSGSD-lex-yesNo-dev"

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

module "cloudwatch_log_group" {
  count  = contains(local.enabled_module_set, "cloudwatch_log_group") ? 1 : 0
  source = "../../modules/cloudwatch_log_group"

  providers = {
    aws = aws.us_east_1
  }

  log_group_name = "/aws/connect/ai-agent-logs-dev"
}

import {
  for_each = contains(local.enabled_module_set, "secrets_manager") ? var.secrets_manager_existing_arns : {}

  to = module.secrets_manager[0].aws_secretsmanager_secret.this[each.key]
  id = each.value
}
