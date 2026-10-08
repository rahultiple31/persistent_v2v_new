variable "aws_region" {
  description = "Default AWS region for backend and unaliased provider operations."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment name."
  type        = string
  default     = "dev"
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
  description = "Optional complete Amazon Connect instance alias override."
  type        = string
  default     = null
}

variable "connect_name_suffix" {
  description = "Suffix used in the Amazon Connect instance alias."
  type        = string
  default     = "connect"
}

variable "enabled_modules" {
  description = "Infrastructure modules enabled for this Terraform state. Supported values: connect, lambda, proxy, v2v."
  type        = list(string)
  default     = ["connect"]

  validation {
    condition     = length(setsubtract(toset([for module_name in var.enabled_modules : lower(module_name)]), toset(["connect", "lambda", "proxy", "v2v"]))) == 0
    error_message = "enabled_modules supports: connect, lambda, proxy, v2v."
  }
}

variable "common_tags" {
  description = "Additional tags applied to all resources."
  type        = map(string)
  default     = {}
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
  default     = "AmazonConnectV2V"
}

variable "frontend_client_name" {
  description = "Cognito User Pool app client name for the V2V application."
  type        = string
  default     = "AmazonConnectV2VFrontend"
}

variable "ssm_hierarchy" {
  description = "SSM Parameter Store hierarchy used by the V2V solution."
  type        = string
  default     = "/AmazonConnectV2V/"

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

variable "proxy_availability_zones" {
  description = "Optional pair of Availability Zones used by the proxy network."
  type        = list(string)
  default     = null

  validation {
    condition     = var.proxy_availability_zones == null ? true : (length(var.proxy_availability_zones) == 2 && length(toset(var.proxy_availability_zones)) == 2)
    error_message = "proxy_availability_zones must be null or contain exactly two distinct Availability Zone names."
  }
}

variable "proxy_vpc_cidr" {
  description = "CIDR block for the dedicated proxy VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "proxy_public_subnet_cidrs" {
  description = "CIDR blocks for the two proxy public subnets."
  type        = list(string)
  default     = ["10.0.0.0/24", "10.0.1.0/24"]

  validation {
    condition     = length(var.proxy_public_subnet_cidrs) == 2
    error_message = "proxy_public_subnet_cidrs must contain exactly two CIDR blocks."
  }
}

variable "proxy_private_subnet_cidrs" {
  description = "CIDR blocks for the two proxy private subnets."
  type        = list(string)
  default     = ["10.0.4.0/22", "10.0.8.0/22"]

  validation {
    condition     = length(var.proxy_private_subnet_cidrs) == 2
    error_message = "proxy_private_subnet_cidrs must contain exactly two CIDR blocks."
  }
}

variable "proxy_enabled" {
  description = "Value written to SSM Parameter Store as the proxy feature switch."
  type        = bool
  default     = true
}

variable "proxy_ecr_repository_name" {
  description = "Optional ECR repository name override for the proxy."
  type        = string
  default     = null
}

variable "proxy_container_image" {
  description = "Optional full image URI deployed to the proxy ECS service."
  type        = string
  default     = null
}

variable "proxy_container_port" {
  description = "Proxy container HTTP and WebSocket port."
  type        = number
  default     = 8080

  validation {
    condition     = var.proxy_container_port >= 1 && var.proxy_container_port <= 65535
    error_message = "proxy_container_port must be between 1 and 65535."
  }
}

variable "proxy_desired_count" {
  description = "Baseline number of proxy ECS tasks."
  type        = number
  default     = 2

  validation {
    condition     = var.proxy_desired_count >= 0
    error_message = "proxy_desired_count must be zero or greater."
  }
}

variable "proxy_min_capacity" {
  description = "Minimum proxy ECS service task count."
  type        = number
  default     = 2

  validation {
    condition     = var.proxy_min_capacity >= 0
    error_message = "proxy_min_capacity must be zero or greater."
  }
}

variable "proxy_max_capacity" {
  description = "Maximum proxy ECS service task count."
  type        = number
  default     = 10

  validation {
    condition     = var.proxy_max_capacity >= 1
    error_message = "proxy_max_capacity must be one or greater."
  }
}

variable "proxy_task_cpu" {
  description = "Fargate CPU units allocated to the proxy task."
  type        = number
  default     = 512

  validation {
    condition     = var.proxy_task_cpu > 0
    error_message = "proxy_task_cpu must be greater than zero."
  }
}

variable "proxy_task_memory" {
  description = "Memory in MiB allocated to the proxy task."
  type        = number
  default     = 1024

  validation {
    condition     = var.proxy_task_memory > 0
    error_message = "proxy_task_memory must be greater than zero."
  }
}

variable "proxy_health_check_path" {
  description = "ALB and container health-check path for the proxy."
  type        = string
  default     = "/healthz"

  validation {
    condition     = startswith(var.proxy_health_check_path, "/")
    error_message = "proxy_health_check_path must start with /."
  }
}

variable "proxy_bedrock_model_id" {
  description = "Bedrock model ID used by the proxy."
  type        = string
  default     = "amazon.nova-2-sonic-v1:0"
}

variable "proxy_fallback_rate_limit_per_minute" {
  description = "Per-user fallback API request limit per minute."
  type        = number
  default     = 60

  validation {
    condition     = var.proxy_fallback_rate_limit_per_minute > 0
    error_message = "proxy_fallback_rate_limit_per_minute must be greater than zero."
  }
}

variable "proxy_max_connections_per_user" {
  description = "Per-user WebSocket connection limit enforced by the proxy."
  type        = number
  default     = 12

  validation {
    condition     = var.proxy_max_connections_per_user > 0
    error_message = "proxy_max_connections_per_user must be greater than zero."
  }
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

variable "dev_support_ai_agent_enabled" {
  description = "Publish the support voice orchestration agent with the Dev Connect target, independently of the legacy agent."
  type        = bool
  default     = false
}

variable "dev_support_ai_prompt_file" {
  description = "Environment-relative path to the support prompt instructions and test metadata YAML."
  type        = string
  default     = "metadata/prompts/btsgsd-support_prompts.yaml"
}

variable "dev_support_ai_python_executable" {
  description = "Python 3 executable for read-only source discovery; use python for local Windows runs."
  type        = string
  default     = "python3"
}

variable "dev_ai_assistant_id" {
  description = "Existing assistant UUID associated with the Dev Connect instance; leave null when Terraform creates the domain."
  type        = string
  default     = null

  validation {
    condition     = !(local.dev_ai_enabled || local.dev_support_ai_enabled) || local.dev_ai_domain_enabled || can(regex("^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$", var.dev_ai_assistant_id))
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
    condition     = !local.deploy_connect || (var.dev_ai_template_bucket == null && !(local.dev_ai_enabled || local.dev_support_ai_enabled)) || can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.dev_ai_template_bucket))
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

variable "proxy_log_retention_days" {
  description = "CloudWatch Logs retention period for proxy logs."
  type        = number
  default     = 90

  validation {
    condition     = var.proxy_log_retention_days > 0
    error_message = "proxy_log_retention_days must be greater than zero."
  }
}
