################################################################################
# Example variable values — copy to terraform.tfvars and fill in your values.
# Mirrors cdk-stacks/config/private-poc.config.ts
################################################################################

# ── General ───────────────────────────────────────────────────────────────────
aws_region          = "us-east-1"
ai_region           = "us-east-1"
stack_name          = "BTSGSD-V2V-US-POC"
nova_sonic_model_id = "amazon.nova-2-sonic-v1:0"
ssm_hierarchy       = "/BTSGSD/V2V/US/POC/"
# Test sign-in (for testing until Ping is reachable): its password is this
# Secrets Manager secret, README: key
# "password", 12+ characters; "off" or no secret = off). Ping sign-in (OIDC
# below) works alongside it. Empty = the test sign-in is removed completely.
test_sign_in_secret_name = "/BTSGSD/V2V/US/POC/testSignIn"

# Voicemail playback in the page: the live VMX3's recordings bucket
# (confirmed 2026-11-06). Empty = off.
voicemail_recordings_bucket = "voicemail-v2v"

tags = {
  # Project = "V2V-POC"
  # Owner   = "platform-team"
}

# ── Network ───────────────────────────────────────────────────────────────────
# Old VPC (the one the VDI reaches today), private subnets us-east-1a / 1b.
# New VPC, for when its network opening is done:
#   vpc_id     = "vpc-0f2abb3d6596a0487"
#   subnet_ids = ["subnet-0c29b5f2c41c73d89", "subnet-0fe7a72e5cef073ad"]
#   secretsmanager_endpoint = false (that VPC already has one, from the Lambda team)
vpc_id     = "vpc-0d53b4822930f6d7c"
subnet_ids = ["subnet-01d52dfbca85dea3b", "subnet-0399e0278d2b09eb5"]

# VDI / Zscaler connector CIDRs that are allowed to reach the load balancer
allowed_cidrs = [
  "10.74.41.132/32",
  "10.74.41.158/32",
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
hostname         = "v2vconnectus.iai-accas-dev.awscloud.abbvienet.com"
hosted_zone_id   = "Z03204381MY7P9A6ZENZD"
hosted_zone_name = "iai-accas-dev.awscloud.abbvienet.com"

# Leave empty for HTTP/port-80 (test stage 1). Set to ACM ARN for HTTPS/443.
# DigiCert certificate for v2vconnectus (trusted by the VDI browsers).
certificate_arn = "arn:aws:acm:us-east-1:518902362956:certificate/78c9215b-da2b-4d0d-aa07-57a7b851452d"
csp_enforced    = false

# ── Amazon Connect ────────────────────────────────────────────────────────────
# SSO (SAML) instance btsgsd-dev-v2v-poc-us-east-1, the same one the CDK uses.
# The softphone pop-up opens its app link in the AWS access portal.
# Earlier instance (no SSO), to use it again:
#   connect_instance_arn = "arn:aws:connect:us-east-1:518902362956:instance/0cc3e955-8cdd-4a82-b6fe-7593e1674ffa"
#   connect_instance_url = "https://abbvie-sd-contactcenter-dev-us.my.connect.aws"
#   connect_login_url    = ""
connect_instance_arn = "arn:aws:connect:us-east-1:518902362956:instance/bcc989e5-cd9d-494f-9cd4-434f39ccc90e"
connect_instance_url = "https://btsgsd-dev-v2v-poc-us-east-1.my.connect.aws"
connect_region       = "us-east-1"
connect_login_url    = "https://d-9067f5545f.awsapps.com/start/#/saml/default/btsgsd-dev-idp-v2v-poc-us-east-1/ins-72232d99753b87d8"

# ── OIDC / Identity Provider ──────────────────────────────────────────────────
# PingFederate dev. It is a confidential client (it needs a client secret), so
# the proxy signs agents in itself (auth_mode = "bff") and the browser only
# holds a session cookie. Endpoints from
# https://federationdev.abbvie.com/.well-known/openid-configuration.
# The proxy must reach federationdev.abbvie.com on 443 from subnet_ids.
auth_mode                   = "bff"
oidc_issuer                 = "https://federationdev.abbvie.com"
oidc_client_id              = "mfa.0017071.abbvieamazon.dev"
oidc_scope                  = "openid" # add "offline_access" if the first sign-in logs refreshToken: false
oidc_audience               = ""       # Not used by bff
oidc_jwks_uri               = "https://federationdev.abbvie.com/pf/JWKS"
oidc_group_claim            = "" # Empty: every Ping user can sign in
oidc_allowed_groups         = [] # Empty: every Ping user can sign in
oidc_authorization_endpoint = "https://federationdev.abbvie.com/as/authorization.oauth2"
oidc_token_endpoint         = "https://federationdev.abbvie.com/as/token.oauth2"
oidc_end_session_endpoint   = "https://federationdev.abbvie.com/idp/startSLO.ping"
oidc_revocation_endpoint    = "https://federationdev.abbvie.com/as/revoke_token.oauth2"
oidc_userinfo_endpoint      = "https://federationdev.abbvie.com/idp/userinfo.openid"
oidc_session_hours          = 12

# Secrets Manager: names only, never values. Both secrets already exist in the
# account (created by hand); Terraform only lets the tasks read them.
oidc_client_secret_name = "v2v/poc/ping-client-secret"
session_key_secret_name = "v2v/poc/session-key"
session_check_minutes   = 30
# One Secrets Manager endpoint per VPC: true while the old VPC has none.
secretsmanager_endpoint = true

# ── WAF ───────────────────────────────────────────────────────────────────────
waf_common_rule_set = false

# ── ECR / Container image ─────────────────────────────────────────────────────
# Run terraform/scripts/build-and-push.sh before terraform apply.
ecr_repository_name = "btsgsd-v2v-us-poc"
container_image_tag = "latest"
