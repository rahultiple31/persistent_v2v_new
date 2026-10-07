environment                = "dev"
project_name               = "btsgsd"
aws_region                 = "us-east-1"
resource_name_prefix       = "btsgsd-dev-us-east-1"
contact_center_alias       = "btsgsd"
connect_instance_alias     = "btsgsd-dev-us-east-1"
connect_name_suffix        = "connect-saml"
connect_admin_user_enabled = true
connect_admin_first_name   = "Lokesh"
connect_admin_last_name    = "Kothapally"
connect_admin_username     = "lokesh.kothapally@abbvie.com"
connect_admin_email        = "lokesh.kothapally@abbvie.com"

common_tags = {
  CostCenter = "contact-center"
  Owner      = "platform-engineering"
}

cognito_domain_prefix   = "btsgsd-dev-us-east-1"
cognito_callback_urls   = ["https://localhost:5173"]
cognito_logout_urls     = ["https://localhost:5173"]
connect_instance_url    = "https://btsgsd-dev-us-east-1.my.connect.aws"
connect_instance_region = "us-east-1"
transcribe_region       = "us-east-1"
translate_region        = "us-east-1"
translate_proxy_enabled = false
polly_region            = "us-east-1"
polly_proxy_enabled     = false
deploy_v2v_assets       = true
app_name                = "btsgsd-dev-us-east-1"
frontend_client_name    = "btsgsd-dev-us-east-1-frontend"
ssm_hierarchy           = "/btsgsd-dev-us-east-1/"

proxy_availability_zones             = null
proxy_vpc_cidr                       = "10.0.0.0/16"
proxy_public_subnet_cidrs            = ["10.0.0.0/24", "10.0.1.0/24"]
proxy_private_subnet_cidrs           = ["10.0.4.0/22", "10.0.8.0/22"]
proxy_enabled                        = true
proxy_ecr_repository_name            = "btsgsd-dev-us-east-1"
proxy_container_image                = null
proxy_container_port                 = 8080
proxy_desired_count                  = 2
proxy_min_capacity                   = 2
proxy_max_capacity                   = 10
proxy_task_cpu                       = 512
proxy_task_memory                    = 1024
proxy_health_check_path              = "/healthz"
proxy_bedrock_model_id               = "amazon.nova-2-sonic-v1:0"
proxy_fallback_rate_limit_per_minute = 150
proxy_max_connections_per_user       = 12
proxy_log_retention_days             = 90

translation_enabled       = true
proxy_integration_enabled = false
bedrock_region            = "us-east-1"
sso_enabled               = false
sso_provider_name         = "EntraID"
csp_enforced              = false

# Enable after verifying the assistant is associated with btsgsd-dev-us-east-1
# and supplying the model, private template bucket and complete tool definitions.
dev_ai_agent_enabled   = false
dev_ai_assistant_id    = "160889f7-d564-47fb-97db-94549fc55993"
dev_ai_prompt_file     = "metadata/prompts/AgentAssistanceOrchestration.yaml"
dev_ai_prompt_model_id = null
dev_ai_template_bucket = null
dev_ai_tools           = []
