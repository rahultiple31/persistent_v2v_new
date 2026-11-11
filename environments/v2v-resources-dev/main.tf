################################################################################
# Root Module — wires all child modules together
# Mirrors the PrivatePocStack in cdk-stacks/lib/private-poc-stack.ts
################################################################################

# ── CloudWatch log group ──────────────────────────────────────────────────────
module "cloudwatch" {
  # source     = "./modules/cloudwatch"
  source     = "../../v2v-resource-modules/cloudwatch"
  stack_name = var.stack_name
}

# ── SSM parameters ────────────────────────────────────────────────────────────
module "ssm" {
  # source        = "./modules/ssm"
  source        = "../../v2v-resource-modules/ssm"
  stack_name    = var.stack_name
  ssm_hierarchy = var.ssm_hierarchy
  ai_region     = var.ai_region
}

# ── ECR repository ────────────────────────────────────────────────────────────
module "ecr" {
  # source          = "./modules/ecr"
  source          = "../../v2v-resource-modules/ecr"
  repository_name = var.ecr_repository_name
}


# ── IAM roles and policies ────────────────────────────────────────────────────
module "iam" {
  # source     = "./modules/iam"
  source     = "../../v2v-resource-modules/iam"
  stack_name = var.stack_name

  aws_region = var.aws_region
  ai_region  = var.ai_region
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id

  nova_sonic_model_id        = var.nova_sonic_model_id
  force_backup_parameter_arn = module.ssm.force_backup_parameter_arn
  log_group_arn              = module.cloudwatch.log_group_arn
  secret_names               = local.sign_in_secret_names

  voicemail_recordings_bucket = var.voicemail_recordings_bucket
}


# ── Networking — security groups + VPC interface endpoints ────────────────────
module "networking" {
  # source     = "./modules/networking"
  source     = "../../v2v-resource-modules/networking"
  stack_name = var.stack_name

  vpc_id               = var.vpc_id
  subnet_ids           = var.subnet_ids
  aws_region           = var.aws_region
  allowed_cidrs        = var.allowed_cidrs
  endpoint_extra_cidrs = var.endpoint_extra_cidrs
  listener_port        = local.listener_port

  # bff and the test sign-in read their secrets at runtime through a Secrets
  # Manager endpoint.
  secretsmanager_endpoint = (local.bff || local.test_sign_in) && var.secretsmanager_endpoint
}

# ── Sign-in settings check ────────────────────────────────────────────────────
# Fails the plan, before anything changes, when the bff settings are incomplete
# (the proxy would otherwise fail at start-up and never become healthy).
resource "terraform_data" "sign_in_settings" {
  input = var.auth_mode

  lifecycle {
    precondition {
      condition     = !local.bff || local.https
      error_message = "auth_mode = \"bff\" needs HTTPS (certificate_arn): its cookies are Secure-only."
    }
    precondition {
      condition     = !local.bff || var.session_key_secret_name != ""
      error_message = "auth_mode = \"bff\" needs session_key_secret_name."
    }
    precondition {
      condition = !local.bff || var.oidc_issuer == "" || alltrue([
        for value in [
          var.oidc_client_id,
          var.oidc_client_secret_name,
          var.oidc_authorization_endpoint,
          var.oidc_token_endpoint,
          var.oidc_jwks_uri,
        ] : value != ""
      ])
      error_message = "auth_mode = \"bff\" with oidc_issuer set also needs oidc_client_id, oidc_client_secret_name, oidc_authorization_endpoint, oidc_token_endpoint and oidc_jwks_uri."
    }
  }
}

# ── Application Load Balancer ─────────────────────────────────────────────────
module "alb" {
  # source     = "./modules/alb"
  source     = "../../v2v-resource-modules/alb"
  stack_name = var.stack_name

  vpc_id                = var.vpc_id
  subnet_ids            = var.subnet_ids
  alb_security_group_id = module.networking.alb_security_group_id
  https                 = local.https
  listener_port         = local.listener_port
  certificate_arn       = var.certificate_arn
  account_id            = data.aws_caller_identity.current.account_id
}

# ── WAF WebACL + ALB association ──────────────────────────────────────────────
module "waf" {
  # source     = "./modules/waf"
  source     = "../../v2v-resource-modules/waf"
  stack_name = var.stack_name

  alb_arn         = module.alb.alb_arn
  common_rule_set = var.waf_common_rule_set
}

# ── ECS cluster + task definition + Fargate service ──────────────────────────
module "ecs" {
  # source     = "./modules/ecs"
  source     = "../../v2v-resource-modules/ecs"
  stack_name = var.stack_name

  aws_region                = var.aws_region
  subnet_ids                = var.subnet_ids
  service_security_group_id = module.networking.service_security_group_id
  target_group_arn          = module.alb.target_group_arn
  task_role_arn             = module.iam.task_role_arn
  execution_role_arn        = module.iam.execution_role_arn
  log_group_name            = module.cloudwatch.log_group_name
  container_image_uri       = "${module.ecr.repository_url}:${var.container_image_tag}"
  container_environment     = local.container_environment
}

# ── Route 53 record + Connect approved origin ─────────────────────────────────
module "dns" {
  # source     = "./modules/dns"
  source     = "../../v2v-resource-modules/dns"
  stack_name = var.stack_name

  hostname             = var.hostname
  hosted_zone_id       = var.hosted_zone_id
  alb_dns_name         = module.alb.alb_dns_name
  alb_zone_id          = module.alb.alb_zone_id
  connect_instance_arn = var.connect_instance_arn
  site_https_origin    = "https://${var.hostname}"
}

