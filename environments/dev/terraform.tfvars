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

# Retain the domain and bucket; keep the legacy agent disabled.
dev_ai_domain_enabled  = true
dev_ai_agent_enabled   = false
dev_ai_agent_test_mode = false
dev_ai_assistant_id    = null
dev_ai_prompt_file     = "metadata/prompts/AgentAssistanceOrchestration.yaml"
dev_ai_prompt_model_id = null
dev_ai_template_bucket = "atsgsd-dev-us-east-1-ai-agent"
dev_ai_tools           = []

# Publish the survey agent copied from SelfServiceOrchestratorVoice.
dev_survey_ai_agent_enabled = true

# Publish the new SupportAgent with the supplied complete voice prompt.
dev_support_ai_agent_enabled = true

# Migrate all custom Dev AI agents to the existing built-in Admin profile.
dev_ai_admin_security_profile_enabled = true

# true = create/retain the gateway stack; false = destroy it on apply.
# Pipeline: targetEnvironment=dev, targetModule=agentcore_gateway.
# Use terraformAction=plan to review, then terraformAction=apply.
# For a new gateway, run apply again to add its generated ID JWT audience.
agentcore_gateway_enabled = true

# Manual deployments use a state key dedicated to the selected module.
enabled_modules                          = ["lambda-nextthink-handoff"]
servicenow_interaction_python_executable = "python"

# Deploy without a guaranteed reservation of 100 while quota is unavailable.
# null omits the CloudFormation concurrency property and uses the shared pool.
# Do not use 0: it disables function invocation.
# Restore 100 after increasing the quota or releasing other reservations.
servicenow_interaction_reserved_concurrency = null

# Use python3 instead on systems where that is the installed executable.
# Optional overrides; the supplied handler defaults remain in effect otherwise:
# servicenow_interaction_environment_variables = {
#   SN_INSTANCE = "abbvienowdev"
#   SN_CTI_RULE = "cti_gsd"
# }

# Nextthink Handoff manual deployment; no separate tfvars file is needed.
nexthink_handoff_python_executable = "python"

# Use the shared unreserved pool without guaranteeing 200 concurrent executions.
# null omits the reservation property and skips the reservation capacity check.
# Do not use 0: it disables function invocation.
# Restore 200 after increasing the quota or releasing other reservations.
nexthink_handoff_reserved_concurrency = null

# The supplied handler's default HTTP read timeout is 10 seconds; the Lambda
# timeout is 8 seconds. Optional shorter HTTP timeouts reduce that risk, but
# secret retrieval, authentication, and a 401 retry must share the same budget.
# nexthink_handoff_environment_variables = {
#   CONNECT_TIMEOUT_SECONDS = "1"
#   READ_TIMEOUT_SECONDS    = "1"
# }

# Set only if the existing secret uses a customer-managed KMS key.
# The key policy must also permit the execution role to decrypt.
# nexthink_handoff_secret_kms_key_arn = "arn:aws:kms:us-east-1:518902362956:key/<key-id>"
