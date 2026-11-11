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
  description = "Amazon Bedrock model ID for Nova Sonic (e.g. amazon.nova-2-sonic-v1:0 or amazon.nova-2-5-sonic)."
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

variable "test_sign_in_secret_name" {
  description = "Name of the Secrets Manager secret that holds the temporary test sign-in password (12+ characters, or \"off\"). Created by hand in the console; Terraform only grants read access. Empty: the test sign-in is removed completely."
  type        = string
  default     = ""
}

variable "voicemail_recordings_bucket" {
  description = "Voicemail playback in the page: the bucket VMX3 writes recordings to (its recording processor's vmx3_recordings_bucket). The proxy reads them with its task role through the VPC's S3 gateway endpoint. Empty: no playback, no S3 access."
  type        = string
  default     = ""

  validation {
    condition     = var.voicemail_recordings_bucket == "" || can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.voicemail_recordings_bucket))
    error_message = "voicemail_recordings_bucket must be an S3 bucket name (lowercase), or empty."
  }
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
  description = "Session length in hours. oidc: the refresh-token lifetime (0 = unknown, no session-expiry warning). bff: how long a sign-in lasts (0 = the proxy's default, 12)."
  type        = number
  default     = 0
}

# ── Server-side sign-in (auth_mode = "bff") ───────────────────────────────────

variable "auth_mode" {
  description = "oidc: the page signs in with the identity provider itself (public client). bff: the proxy signs agents in with the client secret and the browser holds only a session cookie (confidential client, such as Ping dev). bff needs HTTPS."
  type        = string
  default     = "oidc"

  validation {
    condition     = contains(["oidc", "bff"], var.auth_mode)
    error_message = "auth_mode must be \"oidc\" or \"bff\"."
  }
}

variable "oidc_userinfo_endpoint" {
  description = "bff only: OIDC userinfo endpoint (optional)."
  type        = string
  default     = ""
}

variable "oidc_client_secret_name" {
  description = "bff only: name of the Secrets Manager secret that holds the identity provider's client secret. Created by hand; Terraform only grants read access."
  type        = string
  default     = ""
}

variable "session_key_secret_name" {
  description = "bff only: name of the Secrets Manager secret that holds the session-cookie key. Created by hand; Terraform only grants read access."
  type        = string
  default     = ""
}

variable "session_check_minutes" {
  description = "bff only: how often (minutes) the proxy re-checks a signed-in agent with the identity provider."
  type        = number
  default     = 30
}

variable "secretsmanager_endpoint" {
  description = "bff or test sign-in only: true creates a Secrets Manager interface endpoint. Set false in a VPC that already has one with private DNS (only one is allowed per VPC); that endpoint's security group must then allow 443 from the proxy tasks."
  type        = bool
  default     = true
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
