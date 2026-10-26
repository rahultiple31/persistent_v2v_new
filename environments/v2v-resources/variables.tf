################################################################################
# Root Input Variables
# All values mirror cdk-stacks/config/private-poc.config.ts exactly.
################################################################################

# ── General ──────────────────────────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region where the stack is deployed (e.g. us-east-1)."
  type        = string
}

variable "ai_region" {
  description = "Region for Nova Sonic, Transcribe, Translate and Polly VPC endpoints."
  type        = string
}

variable "stack_name" {
  description = "Logical name for the stack, used as a prefix for every resource."
  type        = string
  default     = "BTSGSD-V2V-US-POC"
}

variable "nova_sonic_model_id" {
  description = "Amazon Bedrock model ID for Nova Sonic (e.g. amazon.nova-2-5-sonic)."
  type        = string
  default     = "amazon.nova-2-5-sonic"
}

variable "ssm_hierarchy" {
  description = "Parameter Store key prefix, must end with /. Example: /V2V/POC/"
  type        = string
  default     = "/BTSGSD/V2V/US/POC/"

  validation {
    condition     = endswith(var.ssm_hierarchy, "/")
    error_message = "ssm_hierarchy must end with a forward slash (/)."
  }
}

variable "test_sign_in" {
  description = "true: the temporary password-based sign-in feature is available (switched in Parameter Store). false: it is removed completely."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every resource. Supply any tags required by account policy."
  type        = map(string)
  default     = {}
}

# ── Network ───────────────────────────────────────────────────────────────────

variable "vpc_id" {
  description = "ID of the existing VPC. The stack imports it — no subnets, routes or NAT are created."
  type        = string
}

variable "subnet_ids" {
  description = "Exactly two existing private subnet IDs in different Availability Zones."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) == 2
    error_message = "subnet_ids must contain exactly 2 subnet IDs."
  }
}

variable "allowed_cidrs" {
  description = "CIDR blocks allowed to reach the load balancer (VDI / Zscaler connector ranges)."
  type        = list(string)
}

variable "endpoint_extra_cidrs" {
  description = "Additional CIDR blocks in the VPC that also call the AWS AI services. The interface endpoints use private DNS for the whole VPC, so anything that normally resolves those service addresses needs to be able to reach the endpoints."
  type        = list(string)
  default     = []
}

# ── Site / TLS ────────────────────────────────────────────────────────────────

variable "hostname" {
  description = "Fully-qualified domain name for the agent portal (e.g. v2v.example.com)."
  type        = string
}

variable "hosted_zone_id" {
  description = "Route 53 hosted-zone ID that contains the hostname."
  type        = string
}

variable "hosted_zone_name" {
  description = "Route 53 hosted-zone name (e.g. example.com)."
  type        = string
}

variable "certificate_arn" {
  description = "ACM certificate ARN for HTTPS. Leave empty for HTTP-only (test stage 1)."
  type        = string
  default     = ""
}

variable "csp_enforced" {
  description = "true: Content-Security-Policy header is enforced. false: report-only mode."
  type        = bool
  default     = false
}

# ── Amazon Connect ────────────────────────────────────────────────────────────

variable "connect_instance_arn" {
  description = "ARN of the Amazon Connect instance."
  type        = string
}

variable "connect_instance_url" {
  description = "Access URL of the Amazon Connect instance (e.g. https://my-instance.my.connect.aws)."
  type        = string
}

variable "connect_region" {
  description = "AWS region of the Amazon Connect instance."
  type        = string
}

variable "connect_login_url" {
  description = "SAML login URL for the Connect softphone pop-up. Leave empty for Connect's own login page."
  type        = string
  default     = ""
}

# ── OIDC / Identity Provider ──────────────────────────────────────────────────

variable "oidc_issuer" {
  description = "OIDC issuer URL of the corporate identity provider."
  type        = string
  default     = ""
}

variable "oidc_client_id" {
  description = "OIDC client ID registered with the identity provider."
  type        = string
  default     = ""
}

variable "oidc_scope" {
  description = "OIDC scopes to request (space-separated). Typically 'openid'."
  type        = string
  default     = "openid"
}

variable "oidc_audience" {
  description = "Expected 'aud' claim in the access token. Defaults to oidc_client_id when empty."
  type        = string
  default     = ""
}

variable "oidc_jwks_uri" {
  description = "JWKS URI for verifying access tokens (must be https://)."
  type        = string
  default     = ""
}

variable "oidc_group_claim" {
  description = "Token claim name that lists the user's groups (e.g. groups)."
  type        = string
  default     = ""
}

variable "oidc_allowed_groups" {
  description = "Only users in at least one of these groups can access the proxy. Empty: every signed-in user."
  type        = list(string)
  default     = []
}

variable "oidc_authorization_endpoint" {
  description = "OIDC authorization endpoint. Leave empty to discover from the issuer's .well-known document."
  type        = string
  default     = ""
}

variable "oidc_token_endpoint" {
  description = "OIDC token endpoint. Leave empty to discover from the issuer's .well-known document."
  type        = string
  default     = ""
}

variable "oidc_end_session_endpoint" {
  description = "OIDC end-session endpoint. Leave empty to discover from the issuer's .well-known document."
  type        = string
  default     = ""
}

variable "oidc_revocation_endpoint" {
  description = "OIDC token-revocation endpoint. Leave empty to discover from the issuer's .well-known document."
  type        = string
  default     = ""
}

variable "oidc_session_hours" {
  description = "Refresh-token lifetime in hours. 0: unknown — the webapp shows no session-expiry warning."
  type        = number
  default     = 0
}

# ── WAF ───────────────────────────────────────────────────────────────────────

variable "waf_common_rule_set" {
  description = "true: attach the AWS managed CommonRuleSet to the WAF (with the body-size rule in count mode)."
  type        = bool
  default     = false
}

# ── ECR / Container image ─────────────────────────────────────────────────────

variable "ecr_repository_name" {
  description = "Name of the ECR repository that holds the proxy container image."
  type        = string
  default     = "btsgsd-v2v-us-poc"
}

variable "container_image_tag" {
  description = "Docker image tag to deploy. Run scripts/build-and-push.sh before terraform apply."
  type        = string
  default     = "latest"
}
