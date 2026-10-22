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
locals {
  v2v_translation_enabled = var.translation_enabled
  v2v_translation_mode    = var.translation_enabled ? "direct" : "off"
  transcribe_region       = coalesce(var.transcribe_region, var.bedrock_region)
  translate_region        = coalesce(var.translate_region, var.bedrock_region)
  polly_region            = coalesce(var.polly_region, var.bedrock_region)
}

resource "terraform_data" "v2v_settings" {
  count = local.deploy_v2v ? 1 : 0
  input = local.v2v_translation_mode
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

