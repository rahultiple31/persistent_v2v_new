################################################################################
# Example variable values — copy to terraform.tfvars and fill in your values.
# Mirrors cdk-stacks/config/private-poc.config.ts
################################################################################

# ── General ───────────────────────────────────────────────────────────────────
aws_region          = "us-east-1"
ai_region           = "us-east-1"
stack_name          = "BTSGSD-V2V-US-POC"
nova_sonic_model_id = "amazon.nova-2-5-sonic"
ssm_hierarchy       = "/BTSGSD/V2V/US/POC/"
test_sign_in        = true

tags = {
  # Project = "V2V-POC"
  # Owner   = "platform-team"
}

# ── Network ───────────────────────────────────────────────────────────────────
vpc_id     = "vpc-0f2abb3d6596a0487"
subnet_ids = ["subnet-0c29b5f2c41c73d89", "subnet-0fe7a72e5cef073ad"]

# VDI / Zscaler connector CIDRs that are allowed to reach the load balancer
allowed_cidrs = [
  "10.74.41.132/32",
  "10.225.128.0/18",
  "10.230.128.0/17",
  "10.215.243.0/24",
  "10.75.70.0/24",
  "10.16.25.0/24",
  "10.213.198.0/24",
  "10.191.129.0/24"
]

# Other VPC CIDR ranges that also call the AWS AI services via the VPC endpoints
endpoint_extra_cidrs = []

# ── Site / TLS ────────────────────────────────────────────────────────────────
hostname         = "v2v.iai-accas-dev.awscloud.abbvienet.com"
hosted_zone_id   = "Z03204381MY7P9A6ZENZD"
hosted_zone_name = "iai-accas-dev.awscloud.abbvienet.com"

# Leave empty for HTTP/port-80 (test stage 1). Set to ACM ARN for HTTPS/443.
certificate_arn = "arn:aws:acm:us-east-1:518902362956:certificate/58ceae37-6723-495c-b5ef-ed11d8a28a75"
csp_enforced    = false

# ── Amazon Connect ────────────────────────────────────────────────────────────
connect_instance_arn = "arn:aws:connect:us-east-1:518902362956:instance/0cc3e955-8cdd-4a82-b6fe-7593e1674ffa"
connect_instance_url = "https://abbvie-sd-contactcenter-dev-us.my.connect.aws"
connect_region       = "us-east-1"
connect_login_url    = "" # Set only for SAML/SSO Connect instances

# ── OIDC / Identity Provider ──────────────────────────────────────────────────
oidc_issuer                 = "" # e.g. https://ping.example.com
oidc_client_id              = ""
oidc_scope                  = "openid"
oidc_audience               = "" # Defaults to oidc_client_id when empty
oidc_jwks_uri               = "" # e.g. https://ping.example.com/jwks
oidc_group_claim            = "" # e.g. groups
oidc_allowed_groups         = [] # e.g. ["v2v-users"]
oidc_authorization_endpoint = ""
oidc_token_endpoint         = ""
oidc_end_session_endpoint   = ""
oidc_revocation_endpoint    = ""
oidc_session_hours          = 0

# ── WAF ───────────────────────────────────────────────────────────────────────
waf_common_rule_set = false

# ── ECR / Container image ─────────────────────────────────────────────────────
# Run terraform/scripts/build-and-push.sh before terraform apply.
ecr_repository_name = "btsgsd-v2v-us-poc"
container_image_tag = "latest"
