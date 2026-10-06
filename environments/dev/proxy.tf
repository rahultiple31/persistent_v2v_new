locals {
  proxy_bootstrap_container_image = "public.ecr.aws/docker/library/node:20-alpine"
  proxy_container_image           = coalesce(var.proxy_container_image, local.proxy_bootstrap_container_image)
  proxy_use_bootstrap_container   = !var.proxy_runtime_enabled

  proxy_name_prefix = lower(replace(
    coalesce(var.resource_name_prefix, "${var.project_name}-${var.environment}"),
    "_",
    "-"
  ))
}

module "networking_proxy_us_east_1" {
  count  = local.deploy_proxy ? 1 : 0
  source = "../../modules/networking_proxy"

  providers = {
    aws = aws.proxy_us_east_1
  }

  aws_region           = "us-east-1"
  name_prefix          = local.proxy_name_prefix
  availability_zones   = var.proxy_availability_zones
  vpc_cidr             = var.proxy_vpc_cidr
  public_subnet_cidrs  = var.proxy_public_subnet_cidrs
  private_subnet_cidrs = var.proxy_private_subnet_cidrs
}

module "security_groups_proxy_us_east_1" {
  count  = local.deploy_proxy ? 1 : 0
  source = "../../modules/security_groups_proxy"

  providers = {
    aws = aws.proxy_us_east_1
  }

  name_prefix    = local.proxy_name_prefix
  vpc_id         = module.networking_proxy_us_east_1[0].vpc_id
  container_port = var.proxy_container_port
}

module "logs_proxy_us_east_1" {
  count  = local.deploy_proxy ? 1 : 0
  source = "../../modules/logs_proxy"

  providers = {
    aws = aws.proxy_us_east_1
  }

  name_prefix        = local.proxy_name_prefix
  log_retention_days = var.proxy_log_retention_days
  vpc_id             = module.networking_proxy_us_east_1[0].vpc_id
}

module "iam_proxy_us_east_1" {
  count  = local.deploy_proxy ? 1 : 0
  source = "../../modules/iam_proxy"

  providers = {
    aws = aws.proxy_us_east_1
  }

  name_prefix            = local.proxy_name_prefix
  aws_region             = "us-east-1"
  bedrock_model_id       = var.proxy_bedrock_model_id
  force_backup_parameter = local.force_backup_parameter
}

module "ecr_proxy_us_east_1" {
  count  = local.deploy_proxy ? 1 : 0
  source = "../../modules/ecr_proxy"

  providers = {
    aws = aws.proxy_us_east_1
  }

  name_prefix         = local.proxy_name_prefix
  ecr_repository_name = var.proxy_ecr_repository_name
}

module "alb_proxy_us_east_1" {
  count  = local.deploy_proxy ? 1 : 0
  source = "../../modules/alb_proxy"

  providers = {
    aws = aws.proxy_us_east_1
  }

  name_prefix           = local.proxy_name_prefix
  alb_security_group_id = module.security_groups_proxy_us_east_1[0].alb_security_group_id
  private_subnet_ids    = module.networking_proxy_us_east_1[0].private_subnet_ids
  vpc_id                = module.networking_proxy_us_east_1[0].vpc_id
  container_port        = var.proxy_container_port
  health_check_path     = var.proxy_health_check_path
}

module "ecs_proxy_us_east_1" {
  count  = local.deploy_proxy ? 1 : 0
  source = "../../modules/ecs_proxy"

  providers = {
    aws = aws.proxy_us_east_1
  }

  name_prefix                    = local.proxy_name_prefix
  aws_region                     = "us-east-1"
  container_image                = local.proxy_container_image
  use_bootstrap_container        = local.proxy_use_bootstrap_container
  container_port                 = var.proxy_container_port
  desired_count                  = var.proxy_desired_count
  task_cpu                       = var.proxy_task_cpu
  task_memory                    = var.proxy_task_memory
  health_check_path              = var.proxy_health_check_path
  cognito_user_pool_id           = try(local.v2v_state.user_pool_id, "")
  cognito_client_id              = try(local.v2v_state.user_pool_web_client_id, "")
  allowed_origins                = var.proxy_runtime_enabled ? distinct(concat(var.cognito_callback_urls, [local.v2v_state.v2v_url])) : []
  allowed_groups                 = var.proxy_allowed_groups
  force_backup_parameter         = local.force_backup_parameter
  bedrock_model_id               = var.proxy_bedrock_model_id
  fallback_rate_limit_per_minute = var.proxy_fallback_rate_limit_per_minute
  max_connections_per_user       = var.proxy_max_connections_per_user
  task_execution_role_arn        = module.iam_proxy_us_east_1[0].task_execution_role_arn
  task_role_arn                  = module.iam_proxy_us_east_1[0].task_role_arn
  proxy_log_group_name           = module.logs_proxy_us_east_1[0].proxy_log_group_name
  service_security_group_id      = module.security_groups_proxy_us_east_1[0].service_security_group_id
  private_subnet_ids             = module.networking_proxy_us_east_1[0].private_subnet_ids
  target_group_arn               = module.alb_proxy_us_east_1[0].target_group_arn
}

module "autoscaling_proxy_us_east_1" {
  count  = local.deploy_proxy ? 1 : 0
  source = "../../modules/autoscaling_proxy"

  providers = {
    aws = aws.proxy_us_east_1
  }

  name_prefix      = local.proxy_name_prefix
  ecs_cluster_name = module.ecs_proxy_us_east_1[0].ecs_cluster_name
  ecs_service_name = module.ecs_proxy_us_east_1[0].ecs_service_name
  min_capacity     = var.proxy_min_capacity
  max_capacity     = var.proxy_max_capacity
}

module "alarms_proxy_us_east_1" {
  count  = local.deploy_proxy ? 1 : 0
  source = "../../modules/alarms_proxy"

  providers = {
    aws = aws.proxy_us_east_1
  }

  name_prefix              = local.proxy_name_prefix
  desired_count            = var.proxy_desired_count
  target_group_arn_suffix  = module.alb_proxy_us_east_1[0].target_group_arn_suffix
  load_balancer_arn_suffix = module.alb_proxy_us_east_1[0].load_balancer_arn_suffix
  ecs_cluster_name         = module.ecs_proxy_us_east_1[0].ecs_cluster_name
  ecs_service_name         = module.ecs_proxy_us_east_1[0].ecs_service_name
  nat_gateway_id           = module.networking_proxy_us_east_1[0].nat_gateway_id
}

module "parameters_proxy_us_east_1" {
  count  = local.deploy_proxy ? 1 : 0
  source = "../../modules/parameters_proxy"

  providers = {
    aws = aws.proxy_us_east_1
  }

  ssm_parameter_prefix        = trimsuffix(var.ssm_hierarchy, "/")
  proxy_enabled               = var.proxy_enabled
  selected_availability_zones = module.networking_proxy_us_east_1[0].selected_availability_zones
}

moved {
  from = module.proxy_us_east_1[0].module.networking_proxy
  to   = module.networking_proxy_us_east_1[0]
}

moved {
  from = module.proxy_us_east_1[0].module.security_groups_proxy
  to   = module.security_groups_proxy_us_east_1[0]
}

moved {
  from = module.proxy_us_east_1[0].module.logs_proxy
  to   = module.logs_proxy_us_east_1[0]
}

moved {
  from = module.proxy_us_east_1[0].module.iam_proxy
  to   = module.iam_proxy_us_east_1[0]
}

moved {
  from = module.proxy_us_east_1[0].module.ecr_proxy
  to   = module.ecr_proxy_us_east_1[0]
}

moved {
  from = module.proxy_us_east_1[0].module.alb_proxy
  to   = module.alb_proxy_us_east_1[0]
}

moved {
  from = module.proxy_us_east_1[0].module.ecs_proxy
  to   = module.ecs_proxy_us_east_1[0]
}

moved {
  from = module.proxy_us_east_1[0].module.autoscaling_proxy
  to   = module.autoscaling_proxy_us_east_1[0]
}

moved {
  from = module.proxy_us_east_1[0].module.alarms_proxy
  to   = module.alarms_proxy_us_east_1[0]
}

moved {
  from = module.proxy_us_east_1[0].module.parameters_proxy
  to   = module.parameters_proxy_us_east_1[0]
}

