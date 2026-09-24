variable "aws_region" {
  description = "Default AWS region for backend and unaliased provider operations."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment name."
  type        = string
  default     = "uat"
}

variable "project_name" {
  description = "Project prefix used for names and tags."
  type        = string
  default     = "abbvie"
}

variable "contact_center_alias" {
  description = "Alias prefix for the Amazon Connect UAT instances."
  type        = string
  default     = "connect"
}

variable "connect_name_suffix" {
  description = "Suffix used in the Amazon Connect instance alias."
  type        = string
  default     = "connect"
}

variable "enabled_modules" {
  description = "Infrastructure modules enabled for this Terraform state. Supported values: connect, lambda, v2v."
  type        = list(string)
  default     = ["connect"]

  validation {
    condition     = length(setsubtract(toset([for module_name in var.enabled_modules : lower(module_name)]), toset(["connect", "lambda", "v2v"]))) == 0
    error_message = "enabled_modules supports: connect, lambda, v2v."
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
  description = "Whether Terraform uploads files from v2v_dist_path to the hosting bucket."
  type        = bool
  default     = false
}

variable "v2v_dist_path" {
  description = "Path to the built Vite V2V app dist directory."
  type        = string
  default     = null
}
