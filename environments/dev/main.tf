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

module "btsgsd_support_agent" {
  count  = local.dev_support_ai_enabled ? 1 : 0
  source = "../../modules/connect_ai_agent"

  providers = {
    aws = aws.us_east_1
  }

  assistant_id         = local.dev_ai_assistant_id
  connect_instance_arn = module.connect_us_east_1[0].instance_arn
  template_bucket_name = aws_s3_bucket.dev_ai_template[0].id
  prompt_yaml_file     = abspath("${path.module}/${var.dev_support_ai_prompt_file}")
  python_executable    = var.dev_support_ai_python_executable
  tags                 = local.dev_ai_tags

  depends_on = [
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
  python_executable    = var.dev_support_ai_python_executable
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

  source_file = abspath("${path.module}/metadata/lambda-ctr/lambda_function_ctr_.py")
  handler     = "lambda_function_ctr_.lambda_handler"
  common_tags = local.common_tags
}

module "lambda-connect-daily-ctr-export" {
  count  = contains(local.enabled_module_set, "lambda-connect-daily-ctr-export") ? 1 : 0
  source = "../../modules/lambda-connect-daily-ctr-export"

  providers = {
    aws = aws.us_east_1
  }

  source_file = abspath("${path.module}/metadata/lambda-ctr/lambda_function_ctr_export.py")
  common_tags = local.common_tags
}

module "lambda-ctr-raw" {
  count  = contains(local.enabled_module_set, "lambda-ctr-raw") ? 1 : 0
  source = "../../modules/lambda-ctr-raw"

  providers = {
    aws = aws.us_east_1
  }

  source_file = abspath("${path.module}/metadata/lambda-ctr/lambda_function_ctr_raw.py")
  common_tags = local.common_tags
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
    backendRegion             = data.aws_region.current.name
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
