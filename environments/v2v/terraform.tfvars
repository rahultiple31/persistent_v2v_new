environment                = "dev"
project_name               = "btsgsd"
aws_region                 = "us-east-1"
resource_name_prefix       = "BTSGSD-V2V-US"

# Existing BTFSD-V2V-US code-signing configuration, shared by all V2V Lambdas.
lambda_code_signing_config_arn = "arn:aws:lambda:us-east-1:518902362956:code-signing-config:csc-07e3c2263fd84c053"

contact_center_alias       = "btsgsd"
connect_instance_alias     = "btsgsd-dev-v2v-poc-us-east-1"
connect_name_suffix        = "connect-saml"
connect_admin_user_enabled = false
connect_admin_first_name   = "Lokesh"
connect_admin_last_name    = "Kothapally"
connect_admin_username     = "lokesh.kothapally@abbvie.com"
connect_admin_email        = "lokesh.kothapally@abbvie.com"

queue_name = "BTSGSD-V2V-US-DEV SSO-US-MAIN-QUEUE"
# Resolve this already-claimed number to its Connect resource UUID during planning.
outbound_phone_number    = "+18557117965"
outbound_phone_number_id = null

# Existing resources in V2V instance bcc989e5-cd9d-494f-9cd4-434f39ccc90e.
# Existing resources in V2V instance bcc989e5-cd9d-494f-9cd4-434f39ccc90e.
connect_resources_dependencies = {
  # BTSGSD-V2V-US-DEV SSO-US-MAIN-QUEUE (connect_queue)
  main_queue_id = "6805cf06-6bbc-4c88-af05-baf9eaf23ec5"
  # BTSGSD-V2V-US-outbound-whisper-flow
  outbound_flow_id = "721e589f-fc7f-4965-a64d-3cd0a4a3dd06"
  # BTSGSD-V2V-US-AgentToAgentTransferFlow
  quick_connect_flow_id = "07f52496-7690-41c4-adfa-3c0327c30271"
  # BTSGSD-V2V-US-FF Help Desk, BTSGSD-V2V-US-HR Help Desk
  help_desk_quick_connect_ids = [
    "9d1d6dc1-0c97-4254-bd99-2f4b3255233c",
    "1a3c9499-3beb-4c9a-92b1-383fcf052a55",
  ]
}


# Standalone connect-resources requires the existing V2V dependency UUIDs.
# Uncomment and fill these values before selecting connect-resources.
# connect_resources_dependencies = {
#   hours_of_operation_id = "REPLACE_WITH_EXISTING_HOURS_OF_OPERATION_UUID"
#   main_queue_id         = "REPLACE_WITH_EXISTING_MAIN_QUEUE_UUID"
#   outbound_flow_id      = "REPLACE_WITH_EXISTING_OUTBOUND_WHISPER_FLOW_UUID"
#   quick_connect_flow_id = "REPLACE_WITH_EXISTING_AGENT_TRANSFER_FLOW_UUID"
# }
# If already deployed, move only module.connect_resources[0] into its dedicated
# state. Keep other Connect resources in their owning state; do not copy the
# complete Connect state into the connect-resources state.

# Resolve exported customer-queue dependencies to their existing Dev names.
connect_customer_queue_dependency_names = {
  "VMX3_Main_VM_Module_abbvie-sd-contactcenter-dev-us" = "voicemail-v2v-module"
  "CustomerQueueMOH"                                   = "CustomerQueue.wav"
}

common_tags = {
  CostCenter = "contact-center"
  Owner      = "platform-engineering"
}

cognito_domain_prefix   = "btsgsd-v2v-us"
cognito_callback_urls   = ["https://localhost:5173"]
cognito_logout_urls     = ["https://localhost:5173"]
connect_instance_url    = "https://btsgsd-dev-v2v-poc-us-east-1.my.connect.aws"
connect_instance_region = "us-east-1"
transcribe_region       = "us-east-1"
translate_region        = "us-east-1"
translate_proxy_enabled = false
polly_region            = "us-east-1"
polly_proxy_enabled     = false
deploy_v2v_assets       = true
app_name                = "BTSGSD-V2V-US"
frontend_client_name    = "BTSGSD-V2V-US-frontend"
ssm_hierarchy           = "/BTSGSD-V2V-US/"


bedrock_model_id    = "amazon.nova-2-sonic-v1:0"
translation_enabled = true
bedrock_region      = "us-east-1"
sso_enabled         = false
sso_provider_name   = "EntraID"
csp_enforced        = false

# Retain the domain and bucket; keep the legacy agent disabled.
dev_ai_domain_enabled  = true
dev_ai_agent_enabled   = false
dev_ai_agent_test_mode = false
dev_ai_assistant_id    = null
dev_ai_prompt_file     = "metadata/prompts/AgentAssistanceOrchestration.yaml"
dev_ai_prompt_model_id = null
dev_ai_template_bucket = "btsgsd-v2v-us-atsgsd-dev-us-east-1-ai-agent"
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

# Set false to remove only the integration stack through the gateway choice.
connect_integrations_enabled = true

# Manual deployments use a state key dedicated to the selected module.
enabled_modules                          = ["secrets_manager"]
servicenow_interaction_python_executable = "python"

# Reserve 150 executions; the capacity check requires sufficient regional quota.
servicenow_interaction_reserved_concurrency = 200

servicenow_interaction_environment_variables = {
  SN_INSTANCE = "abbvienowstage"
  SN_CTI_RULE = "cti_gsd"
}

# Nextthink Handoff manual deployment; no separate tfvars file is needed.
nexthink_handoff_python_executable = "python"

# Use the shared unreserved pool without guaranteeing 200 concurrent executions.
# null omits the reservation property and skips the reservation capacity check.
# Do not use 0: it disables function invocation.
# Restore 200 after increasing the quota or releasing other reservations.
nexthink_handoff_reserved_concurrency = 200

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

# Use the dedicated secrets_manager Terraform state for this deployment.
secrets_manager_secrets = {
  "servicenow/stage-dev" = {
    username = "SVC-HCLDESK"
    password = "Ma%Ns7U]w0+D@hwMtPcK@y"
  }

  "servicenow/prod-dev" = {
    username = "SVC-HCLDESK"
    password = "K@tTenFeest0909!"
  }

  "servicenow/details-dev" = {
    username = "SVC-HCLDESK"
    password = "HS0]Bu(dTu.Zu#aiy57Rp8"
  }

  "Nextthink/Clientid/Secretkey-dev" = {
    client_id     = "fc261bfec6164bfdbd4efe467782feb8"
    client_secret = "hux82NQlYW4VmY-jfjMokXFUnWdBaWdMbs2G5_MAzE197pWkjEdXTb9COpe27O3L"
  }
}

# For secrets that already exist, add their actual ARNs before applying.
# This avoids attempting to recreate existing secrets.
secrets_manager_existing_arns = {
  # "Nextthink/Clientid/Secretkey" = "<actual existing secret ARN>"
}


# Existing inbound-flow dependency names.
main_ib_latam_queue_name           = "BTSGSD-V2V-LATAM-MAIN-QUEUE"
main_ib_phone_lookup_function_name = "SNOW_Abbvie"


# VMX3 voicemail module dependencies in V2V instance bcc989e5-cd9d-494f-9cd4-434f39ccc90e.
vmx3_voicemail_queue_arn    = "arn:aws:connect:us-east-1:518902362956:instance/bcc989e5-cd9d-494f-9cd4-434f39ccc90e/queue/257cafaf-87c4-4e32-9f0b-3fbb8b942433"
vmx3_beep_prompt_arn        = "arn:aws:connect:us-east-1:518902362956:instance/bcc989e5-cd9d-494f-9cd4-434f39ccc90e/prompt/ccf6f51f-b39a-4ccd-aa65-80349b07bf65"
vmx3_timestamper_lambda_arn = "arn:aws:lambda:us-east-1:518902362956:function:voicemail-v2v-VoicemailTimestamper"

enable_external_vms = true

# Replace with the actual external voicemail number
external_vm_phone_number = "+18557117965"

# BTSGSD-V2V-US-SNOW reserved concurrency.
snow_lambda_reserved_concurrency = 200

# Allow the specified Lex V2 alias to invoke the V2V callback Lambda.
lex_queueflow_callback_bot_alias_arn = "arn:aws:lex:us-east-1:518902362956:bot-alias/RD35A35EAU/HJAVDZTZBO"
