variable "translation_enabled" {
  description = "Enable Nova voice translation; false keeps the app as a plain softphone."
  type        = bool
}
variable "bedrock_region" {
  description = "Region used by Nova Sonic. Both environments deploy in us-east-1."
  type        = string
  default     = "us-east-1"
}
variable "sso_enabled" {
  description = "Use an existing Cognito identity provider instead of password sign-in."
  type        = bool
  default     = false
}
variable "sso_provider_name" {
  description = "Existing Cognito identity provider name, required when SSO is enabled."
  type        = string
  default     = "EntraID"
  validation {
    condition     = length(trimspace(var.sso_provider_name)) > 0
    error_message = "sso_provider_name must not be empty."
  }
}
variable "csp_enforced" {
  description = "Enforce CSP instead of sending it in report-only mode."
  type        = bool
  default     = false
}
variable "proxy_allowed_groups" {
  description = "Optional Cognito groups allowed to use the translation proxy."
  type        = list(string)
  default     = []
}
variable "state_bucket" {
  description = "S3 bucket containing Terraform state, including an optional existing proxy state."
  type        = string
  default     = "bts-cloud-terraform-tfstate"
}
variable "proxy_integration_enabled" {
  description = "Connect V2V to existing proxy infrastructure; false permits a standalone V2V deployment."
  type        = bool
  default     = false
}

locals {
  translation_mode         = !var.translation_enabled ? "off" : var.proxy_enabled ? "proxy" : "direct"
  proxy_integration_active = local.translation_mode == "proxy" && var.proxy_integration_enabled
  v2v_translation_enabled  = local.translation_mode == "direct" || local.proxy_integration_active
  v2v_translation_mode     = local.v2v_translation_enabled ? local.translation_mode : "off"
  transcribe_region        = coalesce(var.transcribe_region, var.bedrock_region)
  translate_region         = coalesce(var.translate_region, var.bedrock_region)
  polly_region             = coalesce(var.polly_region, var.bedrock_region)
  proxy_state              = try(data.terraform_remote_state.proxy[0].outputs.regional_proxy["us-east-1"], {})
}

data "terraform_remote_state" "proxy" {
  count   = local.deploy_v2v && local.proxy_integration_active ? 1 : 0
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "terraform-state/${var.environment}/us-east-1/proxy/terraform.tfstate"
    region = "us-east-1"
  }
}

resource "terraform_data" "v2v_settings" {
  count = local.deploy_v2v ? 1 : 0
  input = local.translation_mode
  lifecycle {
    precondition {
      condition = alltrue([
        var.aws_region == "us-east-1", var.connect_instance_region == "us-east-1",
        var.bedrock_region == "us-east-1", local.transcribe_region == "us-east-1",
        local.translate_region == "us-east-1", local.polly_region == "us-east-1"
      ])
      error_message = "V2V, Connect, Bedrock, Transcribe, Translate and Polly must all use us-east-1."
    }
  }
}
