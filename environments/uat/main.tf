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
  deploy_v2v         = contains(local.enabled_module_set, "v2v")
}

module "connect_us_east_1" {
  count  = local.deploy_connect ? 1 : 0
  source = "../../modules/connect"

  providers = {
    aws = aws.us_east_1
  }

  project_name         = var.project_name
  environment          = var.environment
  aws_region           = "us-east-1"
  region_code          = "us-east-1"
  common_tags          = local.common_tags
  contact_center_alias = var.contact_center_alias
  service_name_suffix  = var.connect_name_suffix
  admin_user_enabled   = var.connect_admin_user_enabled
  admin_user_first_name = var.connect_admin_first_name
  admin_user_last_name = var.connect_admin_last_name
  admin_user_username  = var.connect_admin_username
  admin_user_email     = var.connect_admin_email
}

module "lambda_us_east_1" {
  count  = local.deploy_lambda ? 1 : 0
  source = "../../modules/lambda"

  providers = {
    aws = aws.us_east_1
  }

  project_name        = var.project_name
  environment         = var.environment
  aws_region          = "us-east-1"
  region_code         = "us-east-1"
  common_tags         = local.common_tags
  lambda_name_suffix = var.lambda_name_suffix
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
  name_prefix = lower(replace("${var.project_name}-${var.environment}-${var.app_name}", "_", "-"))

  frontend_config = {
    backendRegion         = data.aws_region.current.name
    identityPoolId        = try(module.cognito_v2v[0].identity_pool_id, "")
    userPoolId            = try(module.cognito_v2v[0].user_pool_id, "")
    userPoolWebClientId   = try(module.cognito_v2v[0].user_pool_web_client_id, "")
    cognitoDomainURL      = try(module.cognito_v2v[0].cognito_domain_url, "")
    connectInstanceURL    = var.connect_instance_url
    connectInstanceRegion = var.connect_instance_region
    transcribeRegion      = var.transcribe_region
    translateRegion       = var.translate_region
    translateProxyEnabled = tostring(var.translate_proxy_enabled)
    pollyRegion           = var.polly_region
    pollyProxyEnabled     = tostring(var.polly_proxy_enabled)
  }

  ssm_parameters = {
    cognitoDomainPrefix   = var.cognito_domain_prefix
    cognitoCallbackUrls   = join(",", var.cognito_callback_urls)
    cognitoLogoutUrls     = join(",", var.cognito_logout_urls)
    connectInstanceURL    = var.connect_instance_url
    connectInstanceRegion = var.connect_instance_region
    transcribeRegion      = var.transcribe_region
    translateRegion       = var.translate_region
    translateProxyEnabled = tostring(var.translate_proxy_enabled)
    pollyRegion           = var.polly_region
    pollyProxyEnabled     = tostring(var.polly_proxy_enabled)
  }
}

module "s3_v2v" {
  count  = local.deploy_v2v ? 1 : 0
  source = "../../modules/s3_v2v"

  providers = {
    aws = aws.us_east_1
  }

  app_name             = var.app_name
  v2v_root_prefix      = var.v2v_root_prefix
  deploy_v2v_assets    = var.deploy_v2v_assets
  v2v_dist_path        = var.v2v_dist_path
  frontend_config      = local.frontend_config
  common_tags          = local.common_tags
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
  polly_region                    = var.polly_region
  polly_proxy_enabled             = var.polly_proxy_enabled
  translate_region                = var.translate_region
  translate_proxy_enabled         = var.translate_proxy_enabled
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

  name_prefix      = local.name_prefix
  identity_pool_id = try(module.cognito_v2v[0].identity_pool_id, "")
  common_tags      = local.common_tags
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
