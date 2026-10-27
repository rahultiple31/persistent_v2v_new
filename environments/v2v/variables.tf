variable "aws_region" {
  description = "Default AWS region for backend and unaliased provider operations."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment name."
  type        = string
  default     = "v2v"
}

variable "project_name" {
  description = "Project prefix used for names and tags."
  type        = string
  default     = "abbvie"
}

variable "resource_name_prefix" {
  description = "Optional prefix used for named Dev resources."
  type        = string
  default     = null

  validation {
    condition     = var.resource_name_prefix == null || can(regex("^[A-Za-z0-9][A-Za-z0-9_-]{0,47}$", var.resource_name_prefix))
    error_message = "resource_name_prefix must be 1-48 characters and contain only letters, numbers, hyphens, or underscores."
  }
}

variable "contact_center_alias" {
  description = "Alias prefix for the Amazon Connect dev instances."
  type        = string
  default     = "connect"
}

variable "connect_instance_alias" {
  description = "Existing Amazon Connect instance alias for the V2V POC."
  type        = string
  default     = "btsgsd-dev-v2v-poc-us-east-1"
}

variable "connect_name_suffix" {
  description = "Suffix used in the Amazon Connect instance alias."
  type        = string
  default     = "connect"
}

variable "queue_name" {
  description = "Name of the managed Dev Connect inbound queue."
  type        = string
  default     = "BTSGSD-V2V-US-DEV SSO-US-MAIN-QUEUE"
}

variable "outbound_phone_number_id" {
  description = "Optional claimed phone-number UUID. Takes precedence over outbound_phone_number; null enables lookup by telephone number when configured."
  type        = string
  default     = null

  validation {
    condition     = var.outbound_phone_number_id == null || can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.outbound_phone_number_id))
    error_message = "outbound_phone_number_id must be a claimed phone-number UUID. Use outbound_phone_number for an E.164 telephone number."
  }
}

variable "outbound_phone_number" {
  description = "Optional E.164 number already claimed by the selected Connect instance, resolved to its UUID during planning."
  type        = string
  default     = null

  validation {
    condition     = var.outbound_phone_number == null || can(regex("^\\+[1-9][0-9]{1,14}$", var.outbound_phone_number))
    error_message = "outbound_phone_number must use E.164 format, for example +18557117965, without spaces or hyphens."
  }
}

variable "moh_30sec_prompt_s3_uri" {
  description = "Optional S3 URI of the MOH_30SEC WAV prompt."
  type        = string
  default     = null
}

variable "enabled_modules" {
  description = "Infrastructure modules enabled for this Terraform state."
  type        = list(string)
  default     = ["connect"]

  validation {
    condition = length(setsubtract(
      toset([for name in var.enabled_modules : lower(name)]),
      toset([
        "connect",
        "connect-resources",
        "lambda",
        "v2v",
        "s3_connect_reporting",
        "lambda-ctr-survey",
        "lambda-connect-daily-ctr-export",
        "lambda-ctr-raw",
        "btsgsd-v2v-us-snow",
        "btsgsd-v2v-us-servicenow_interaction",
        "btsgsd-v2v-us-nextthink_handoff",
        "iam-ctr",
        "secrets_manager",
        "cloudwatch_log_group",
        "btsgsd-intent-kb",
        "lex_bot",
        "dynamodb",
        "code-signing"
      ])
    )) == 0
    error_message = "enabled_modules contains an unsupported module name."
  }
}

variable "connect_resources_dependencies" {
  description = "Existing Connect resource UUIDs used by the standalone connect-resources deployment."

  type = object({
    main_queue_id               = string
    outbound_flow_id            = string
    quick_connect_flow_id       = string
    help_desk_quick_connect_ids = optional(list(string), [])
  })

  default = null

  validation {
    condition = (
      !contains(
        [for name in var.enabled_modules : lower(name)],
        "connect-resources"
      ) || var.connect_resources_dependencies != null
    )

    error_message = "Set connect_resources_dependencies to the existing V2V resource UUIDs."
  }

  validation {
    condition = var.connect_resources_dependencies == null ? true : alltrue([
      for id in concat(
        [
          var.connect_resources_dependencies.main_queue_id,
          var.connect_resources_dependencies.outbound_flow_id,
          var.connect_resources_dependencies.quick_connect_flow_id,
        ],
        var.connect_resources_dependencies.help_desk_quick_connect_ids,
      ) :
      can(regex(
        "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
        id
      ))
    ])

    error_message = "Every connect_resources_dependencies value must be an actual resource UUID."
  }

  validation {
    condition = (
      !contains(
        [for name in var.enabled_modules : lower(name)],
        "connect-resources"
      ) || try(length(var.connect_resources_dependencies.help_desk_quick_connect_ids) > 0, false)
    )

    error_message = "Set connect_resources_dependencies.help_desk_quick_connect_ids to the FF and HR Help Desk quick connect IDs."
  }
}

variable "secrets_manager_secrets" {
  description = "Secret payloads loaded from terraform.tfvars."
  type        = map(map(string))
  sensitive   = true
  default     = {}
}

variable "secrets_manager_existing_arns" {
  description = "Existing secret names and ARNs to import; leave empty for new secrets."
  type        = map(string)
  default     = {}
}

variable "common_tags" {
  description = "Additional tags applied to all resources."
  type        = map(string)
  default     = {}
}

variable "agentcore_gateway_enabled" {
  description = "Create the Dev AgentCore gateway stack when true; remove it on apply when false."
  type        = bool
  default     = true
}

variable "agentcore_gateway_id_audience" {
  description = "Generated Gateway ID used as the second allowed JWT audience."
  type        = string
  default     = null

  validation {
    condition = var.agentcore_gateway_id_audience == null ? true : can(
      regex("^([0-9a-z][-]?){1,100}-[a-z0-9]{10}$", var.agentcore_gateway_id_audience)
    )
    error_message = "Use the actual Gateway ID returned by agentcore_gateway.id."
  }
}

variable "servicenow_interaction_environment_variables" {
  description = "Optional environment overrides for the Interaction Lambda, including SN_INSTANCE and SN_CTI_RULE."
  type        = map(string)
  default     = {}
}

variable "servicenow_interaction_python_executable" {
  description = "Python executable for the read-only Interaction Lambda concurrency check; use python on Windows."
  type        = string
  default     = "python3"
}

variable "servicenow_interaction_reserved_concurrency" {
  description = "Reserved concurrency for ServiceNow Interaction; null uses the shared unreserved pool."
  type        = number
  default     = 100
  nullable    = true

  validation {
    condition = var.servicenow_interaction_reserved_concurrency == null ? true : (
      var.servicenow_interaction_reserved_concurrency >= 1 &&
      floor(var.servicenow_interaction_reserved_concurrency) == var.servicenow_interaction_reserved_concurrency
    )
    error_message = "Use null or a positive whole number."
  }
}

variable "nexthink_handoff_python_executable" {
  description = "Python executable for the read-only Nexthink concurrency check."
  type        = string
  default     = "python3"
}

variable "nexthink_handoff_reserved_concurrency" {
  description = "Reserved concurrency for Nexthink Handoff; null uses the shared unreserved pool."
  type        = number
  default     = 200
  nullable    = true

  validation {
    condition = var.nexthink_handoff_reserved_concurrency == null ? true : (
      var.nexthink_handoff_reserved_concurrency >= 1 &&
      floor(var.nexthink_handoff_reserved_concurrency) == var.nexthink_handoff_reserved_concurrency
    )
    error_message = "Use null or a positive whole number."
  }
}

variable "nexthink_handoff_environment_variables" {
  description = "Optional Nexthink handler environment overrides."
  type        = map(string)
  default     = {}
}

variable "nexthink_handoff_secret_kms_key_arn" {
  description = "Set when the existing Nexthink secret uses a customer-managed KMS key."
  type        = string
  default     = null
}

variable "connect_flow_python_executable" {
  description = "Python executable for read-only Connect flow dependency resolution; AWS CLI must also be installed."
  type        = string
  default     = "python3"
}

variable "connect_customer_queue_dependency_names" {
  description = "Optional exported-name to Dev-name mapping for customer-queue prompts, data tables and flow modules."
  type        = map(string)
  default     = {}
}

variable "snow_lambda_environment_variables" {
  description = "Optional environment settings for SNOW_btsgsd-dev, including SN_INSTANCE and SN_SECRET_NAME."
  type        = map(string)
  default     = {}
}

variable "snow_lambda_python_executable" {
  description = "Python executable for the SNOW Lambda read-only AWS concurrency check."
  type        = string
  default     = "python3"
}

variable "snow_lambda_reserved_concurrency" {
  description = "Reserved concurrency for SNOW_btsgsd-dev. Null (default) reserves none, because the dev account has only 100 unreserved executions; set 300 once the regional Lambda quota allows at least 400 unreserved."
  type        = number
  default     = null
  nullable    = true
}

variable "lambda_name_suffix" {
  description = "Suffix used in the Lambda function name."
  type        = string
  default     = "lambda-test"
}

variable "connect_admin_user_enabled" {
  description = "Whether to create an initial Amazon Connect administrator user."
  type        = bool
  default     = false
}

variable "connect_admin_first_name" {
  description = "First name for the Amazon Connect administrator user."
  type        = string
  default     = null
}

variable "connect_admin_last_name" {
  description = "Last name for the Amazon Connect administrator user."
  type        = string
  default     = null
}

variable "connect_admin_username" {
  description = "Case-sensitive SAML username for the Amazon Connect administrator; it must match the IdP RoleSessionName."
  type        = string
  default     = null
}

variable "connect_admin_email" {
  description = "Secondary notification email for the SAML Amazon Connect administrator."
  type        = string
  default     = null
}

variable "app_name" {
  description = "Application name used for AWS resource names."
  type        = string
  default     = "BTSGSD-V2V-US-AmazonConnectV2V"
}

variable "frontend_client_name" {
  description = "Cognito User Pool app client name for the V2V application."
  type        = string
  default     = "BTSGSD-V2V-US-AmazonConnectV2VFrontend"
}

variable "ssm_hierarchy" {
  description = "SSM Parameter Store hierarchy used by the V2V solution."
  type        = string
  default     = "/BTSGSD-V2V-US-AmazonConnectV2V/"

  validation {
    condition     = startswith(var.ssm_hierarchy, "/") && length(regexall("//", var.ssm_hierarchy)) == 0
    error_message = "ssm_hierarchy must start with / and must not contain double slashes."
  }
}

variable "v2v_root_prefix" {
  description = "S3 object prefix that CloudFront serves as the V2V application root."
  type        = string
  default     = "V2VRoot/"

  validation {
    condition     = var.v2v_root_prefix == "" || (!startswith(var.v2v_root_prefix, "/") && length(regexall("//", var.v2v_root_prefix)) == 0)
    error_message = "v2v_root_prefix must be empty or a relative S3 prefix without a leading slash or double slashes."
  }
}

variable "v2v_staging_prefix" {
  description = "S3 object prefix reserved for V2V staging artifacts."
  type        = string
  default     = "V2VStaging/"

  validation {
    condition     = var.v2v_staging_prefix == "" || (!startswith(var.v2v_staging_prefix, "/") && length(regexall("//", var.v2v_staging_prefix)) == 0)
    error_message = "v2v_staging_prefix must be empty or a relative S3 prefix without a leading slash or double slashes."
  }
}

variable "cognito_domain_prefix" {
  description = "Globally unique Cognito hosted UI domain prefix. Must not contain aws, amazon, or cognito."
  type        = string
}

variable "cognito_callback_urls" {
  description = "Additional Cognito callback URLs, for example local development URLs."
  type        = list(string)
  default     = ["https://localhost:5173"]
}

variable "cognito_logout_urls" {
  description = "Additional Cognito logout URLs, for example local development URLs."
  type        = list(string)
  default     = ["https://localhost:5173"]
}

variable "connect_instance_url" {
  description = "Existing Amazon Connect instance URL used by the embedded CCP."
  type        = string
}

variable "connect_instance_region" {
  description = "AWS Region of the existing Amazon Connect instance."
  type        = string
}

variable "transcribe_region" {
  description = "AWS Region used by Amazon Transcribe streaming."
  type        = string
  default     = "us-east-1"
}

variable "translate_region" {
  description = "AWS Region used by Amazon Translate."
  type        = string
  default     = "us-east-1"
}

variable "translate_proxy_enabled" {
  description = "Whether CloudFront should proxy browser requests to Amazon Translate."
  type        = bool
  default     = true
}

variable "polly_region" {
  description = "AWS Region used by Amazon Polly."
  type        = string
  default     = "us-east-1"
}

variable "polly_proxy_enabled" {
  description = "Whether CloudFront should proxy browser requests to Amazon Polly."
  type        = bool
  default     = true
}

variable "deploy_v2v_assets" {
  description = "Whether the deployment pipeline uploads the built webapp without deleting prior assets."
  type        = bool
  default     = false
}

variable "v2v_dist_path" {
  description = "Path to the built Vite V2V app dist directory."
  type        = string
  default     = null
}

variable "bedrock_model_id" {
  description = "Bedrock model ID used for direct V2V translation."
  type        = string
  default     = "amazon.nova-2-sonic-v1:0"
}

variable "dev_ai_domain_enabled" {
  description = "Whether to create and associate a new AI domain with the Dev Connect target; independent of custom agent deployment."
  type        = bool
  default     = false
}

variable "dev_ai_agent_enabled" {
  description = "Whether to provision and publish the Dev AI agent with the Connect target; ignored for other targets."
  type        = bool
  default     = false
}

variable "dev_ai_agent_test_mode" {
  description = "Allow a prompt-only Dev smoke-test agent without tools; does not configure knowledge retrieval, note generation or live flow activation."
  type        = bool
  default     = false
}

variable "dev_ai_admin_security_profile_enabled" {
  description = "Assign the existing Admin security profile to all custom AI agents in the Dev assistant and detach their previous profiles; ignored outside the Connect target."
  type        = bool
  default     = false
}

variable "dev_ai_security_profile_python_executable" {
  description = "Python 3 executable for applying AI-agent Admin security-profile assignments; use python for local Windows runs."
  type        = string
  default     = "python3"
}

variable "dev_support_ai_agent_enabled" {
  description = "Publish btsgsd-SupportAgent and its orchestration prompt with the Dev Connect target."
  type        = bool
  default     = false

  validation {
    condition     = !var.dev_support_ai_agent_enabled || !local.deploy_connect || var.dev_ai_admin_security_profile_enabled
    error_message = "Enable dev_ai_admin_security_profile_enabled when deploying btsgsd-SupportAgent so its required Admin security profile is assigned."
  }
}

variable "dev_support_ai_prompt_file" {
  description = "Environment-relative path to the complete SupportAgent system prompt and conversation messages."
  type        = string
  default     = "metadata/prompts/btsgsd-SupportAgent-prompt.yaml"
}

variable "dev_support_ai_python_executable" {
  description = "Python 3 executable for read-only SupportAgent source discovery; use python for local Windows runs."
  type        = string
  default     = "python3"
}

variable "dev_survey_ai_python_executable" {
  description = "Python 3 executable for read-only source discovery; use python for local Windows runs."
  type        = string
  default     = "python3"
}

variable "dev_survey_ai_agent_enabled" {
  description = "Publish the survey voice orchestration agent with the Dev Connect target, independently of the legacy agent."
  type        = bool
  default     = false
}

variable "dev_survey_ai_prompt_file" {
  description = "Environment-relative path to the survey prompt instructions YAML."
  type        = string
  default     = "metadata/prompts/btsgsd-ai-survey-prompt.yaml"
}

variable "dev_ai_assistant_id" {
  description = "Existing assistant UUID associated with the Dev Connect instance; leave null when Terraform creates the domain."
  type        = string
  default     = null

  validation {
    condition     = !(local.dev_ai_enabled || local.dev_survey_ai_enabled || local.dev_support_ai_enabled || local.dev_ai_admin_security_profile_enabled) || local.dev_ai_domain_enabled || can(regex("^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$", var.dev_ai_assistant_id))
    error_message = "Enable dev_ai_domain_enabled to create a Dev assistant, or supply an existing assistant UUID associated with the Dev Connect instance."
  }

  validation {
    condition     = !local.dev_ai_domain_enabled || var.dev_ai_assistant_id == null
    error_message = "Leave dev_ai_assistant_id null when creating the Dev AI domain. To reuse an existing assistant, disable dev_ai_domain_enabled."
  }
}

variable "dev_ai_prompt_file" {
  description = "Environment-relative path to the complete UTF-8 orchestration prompt YAML."
  type        = string
  default     = "metadata/prompts/AgentAssistanceOrchestration.yaml"
}

variable "dev_ai_prompt_model_id" {
  description = "Connect-supported orchestration model ID for us-east-1."
  type        = string
  default     = null

  validation {
    condition     = !local.dev_ai_enabled || can(regex("\\S", var.dev_ai_prompt_model_id))
    error_message = "Set dev_ai_prompt_model_id in Dev Terraform values to a supported Connect orchestration model."
  }
}

variable "dev_ai_template_bucket" {
  description = "Name of the private CloudFormation template bucket Terraform manages in us-east-1; retained while configured even when the custom agent is disabled."
  type        = string
  default     = null

  validation {
    condition     = !local.deploy_connect || (var.dev_ai_template_bucket == null && !(local.dev_ai_enabled || local.dev_survey_ai_enabled || local.dev_support_ai_enabled)) || can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.dev_ai_template_bucket))
    error_message = "Set dev_ai_template_bucket in Dev Terraform values to a valid S3 bucket name without underscores."
  }
}

variable "dev_ai_tools" {
  description = "Complete CloudFormation-format tool configurations, including ToolName, ToolType and applicable ToolId and schema settings."
  type        = any
  default     = []
  sensitive   = true

  validation {
    condition = !local.dev_ai_enabled || try((var.dev_ai_agent_test_mode && length(var.dev_ai_tools) == 0) || (length(var.dev_ai_tools) > 0 && alltrue([
      for tool in var.dev_ai_tools : length(trimspace(tool.ToolName)) > 0 && contains(["MODEL_CONTEXT_PROTOCOL", "RETURN_TO_CONTROL", "CONSTANT"], tool.ToolType)
      ]) && alltrue([
      for required_tool in ["Retrieve", "GenerateNotes"] : contains([for tool in var.dev_ai_tools : tool.ToolName], required_tool)
    ])), false)
    error_message = "Supply complete Retrieve and GenerateNotes configurations with valid ToolName and ToolType fields, or explicitly enable dev_ai_agent_test_mode with an empty tool list for prompt-only testing."
  }
}

variable "connect_integrations_enabled" {
  description = "Create or retain the Connect MCP integration; false removes only the integration stack."
  type        = bool
  default     = true
}

variable "lex_queueflow_callback_bot_alias_arn" {
  description = "Optional Lex V2 bot alias ARN allowed to invoke the callback Lambda."
  type        = string
  default     = null
}

variable "lex_yesno_bot_alias_arn" {
  description = "Optional Lex V2 bot alias ARN allowed to invoke the Yes/No Lambda."
  type        = string
  default     = null
}


variable "main_ib_latam_queue_name" {
  description = "Existing LATAM queue in the Dev Connect instance."
  type        = string
  default     = "BTSGSD-DEV-SSO-LATAM-MAIN-QUEUE"
}

variable "vmx3_voicemail_queue_arn" {
  description = "Existing voicemail queue ARN in the V2V Connect instance; required for the connect deployment group."
  type        = string
  default     = null
}

variable "vmx3_beep_prompt_arn" {
  description = "Existing Beep.wav prompt ARN in the V2V Connect instance; required for the connect deployment group."
  type        = string
  default     = null
}

variable "vmx3_timestamper_lambda_arn" {
  description = "Existing VMX3 timestamper Lambda ARN; required for the connect deployment group."
  type        = string
  default     = null
}

variable "main_ib_phone_lookup_function_name" {
  description = "Existing phone lookup Lambda used by the inbound flow."
  type        = string
  default     = "SNOW_Abbvie"
}

variable "lambda_code_signing_config_arn" {
  description = "ARN of the BTFSD-V2V-US Lambda code-signing configuration."
  type        = string
  default     = null

  validation {
    condition = (
      var.lambda_code_signing_config_arn == null ||
      can(regex(
        "^arn:aws:lambda:us-east-1:518902362956:code-signing-config:csc-[A-Za-z0-9]+$",
        var.lambda_code_signing_config_arn
      ))
    )
    error_message = "Provide the actual V2V Lambda code-signing configuration ARN."
  }

  validation {
    condition = (
      length(setintersection(
        toset([for name in var.enabled_modules : lower(name)]),
        toset([
          "connect",
          "lambda",
          "lambda-ctr-survey",
          "lambda-connect-daily-ctr-export",
          "lambda-ctr-raw",
          "btsgsd-v2v-us-snow",
          "btsgsd-v2v-us-servicenow_interaction",
          "btsgsd-v2v-us-nextthink_handoff"
        ])
      )) == 0 ||
      var.lambda_code_signing_config_arn != null
    )
    error_message = "Set lambda_code_signing_config_arn before deploying a V2V Lambda group."
  }
}

variable "enable_signing_profile" {
  description = "Create the signing profile when the code-signing deployment group is selected."
  type        = bool
  default     = true
  nullable    = false
}

variable "enable_code_signing_config" {
  description = "Create a Warn-mode configuration in the code-signing group; requires enable_signing_profile."
  type        = bool
  default     = true
  nullable    = false

  validation {
    condition = (
      !contains([for name in var.enabled_modules : lower(name)], "code-signing") ||
      !var.enable_code_signing_config || var.enable_signing_profile
    )
    error_message = "enable_code_signing_config requires enable_signing_profile=true in the code-signing group."
  }
}

variable "signing_profile_name" {
  description = "AWS Signer profile name. Preserve the existing name to avoid replacing a deployed profile."
  type        = string
  default     = "BTFSD_V2V_US"
  nullable    = false

  validation {
    condition     = can(regex("^[A-Za-z0-9_]{2,64}$", var.signing_profile_name))
    error_message = "signing_profile_name must contain 2-64 letters, digits, or underscores."
  }
}

variable "enable_external_vms" {
  type    = bool
  default = true
}

variable "external_vm_phone_number" {
  description = "External voicemail destination in E.164 format."
  type        = string
  default     = null

  validation {
    condition = var.external_vm_phone_number == null ? true : can(
      regex("^\\+[1-9][0-9]{1,14}$", var.external_vm_phone_number)
    )
    error_message = "Use an E.164 destination number, such as +18557117965."
  }
}
