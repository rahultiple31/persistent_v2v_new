################################################################################
# Local Values
# Derived from input variables — mirrors the CDK stack's inline computations.
################################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  # ── Protocol / origin ────────────────────────────────────────────────────
  https         = var.certificate_arn != ""
  listener_port = local.https ? 443 : 80
  site_origin   = "${local.https ? "https" : "http"}://${var.hostname}"

  # ── OIDC audience (defaults to client_id) ────────────────────────────────
  oidc_audience = var.oidc_audience != "" ? var.oidc_audience : var.oidc_client_id

  # ── Test sign-in SSM parameter (created by hand as SecureString) ─────────
  test_sign_in_parameter_name = "${var.ssm_hierarchy}testSignIn"
  test_sign_in_parameter_arn  = "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/${trimprefix(local.test_sign_in_parameter_name, "/")}"

  # ── Content-Security-Policy computation (mirrors CDK's contentSecurityPolicy()) ──
  # Extract scheme+host origin from a URL; returns "" on empty/invalid input.
  oidc_raw_urls         = compact([var.oidc_issuer, var.oidc_token_endpoint, var.oidc_revocation_endpoint])
  oidc_origins          = distinct(compact([for u in local.oidc_raw_urls : try(regex("^(https?://[^/?#]+)", u)[0], "")]))
  identity_provider_csp = join(" ", local.oidc_origins)

  connect_instance_origin = try(regex("^(https?://[^/?#]+)", var.connect_instance_url)[0], "")
  connect_signalling      = "wss://*.connect-telecom.${var.connect_region}.amazonaws.com"

  csp_connect_src = join(" ", compact([local.identity_provider_csp, local.connect_instance_origin, local.connect_signalling]))
  csp_frame_src   = local.connect_instance_origin != "" ? local.connect_instance_origin : "'none'"

  csp_base_directives = [
    "default-src 'self'",
    "script-src 'self'",
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data: blob:",
    "font-src 'self' data:",
    "media-src 'self' blob: data:",
    "connect-src 'self' ${local.csp_connect_src}",
    "frame-src ${local.csp_frame_src}",
    "worker-src 'self' blob:",
    "object-src 'none'",
    "base-uri 'self'",
    "form-action 'self'",
    "frame-ancestors 'none'",
  ]
  # upgrade-insecure-requests is added only when HTTPS is active AND CSP is enforced
  csp_upgrade_directive   = local.https && var.csp_enforced ? ["upgrade-insecure-requests"] : []
  content_security_policy = join("; ", concat(local.csp_base_directives, local.csp_upgrade_directive))

  # ── Webapp frontend config JSON (served by proxy as /frontend-config.js) ─
  webapp_config_base = {
    oidcIssuer                = var.oidc_issuer
    oidcClientId              = var.oidc_client_id
    oidcScope                 = var.oidc_scope
    oidcAuthorizationEndpoint = var.oidc_authorization_endpoint
    oidcTokenEndpoint         = var.oidc_token_endpoint
    oidcEndSessionEndpoint    = var.oidc_end_session_endpoint
    oidcRevocationEndpoint    = var.oidc_revocation_endpoint
    connectInstanceURL        = var.connect_instance_url
    connectInstanceRegion     = var.connect_region
  }
  # refreshTokenValidityHours only when session lifetime is known (sessionHours > 0)
  webapp_config_session = var.oidc_session_hours > 0 ? { refreshTokenValidityHours = tostring(var.oidc_session_hours) } : {}
  # connectLoginUrl only for SAML/SSO Connect instances
  webapp_config_login = var.connect_login_url != "" ? { connectLoginUrl = var.connect_login_url } : {}
  webapp_config       = merge(local.webapp_config_base, local.webapp_config_session, local.webapp_config_login)
  webapp_config_json  = jsonencode(local.webapp_config)

  # ── Container environment variables ──────────────────────────────────────
  # CSP_REPORT_ONLY = true when csp_enforced = false (report-only mode)
  csp_report_only = var.csp_enforced ? "false" : "true"

  container_env_base = [
    { name = "NODE_ENV", value = "production" },
    { name = "PORT", value = "8080" },
    { name = "LOG_LEVEL", value = "info" },
    { name = "OIDC_ISSUER", value = var.oidc_issuer },
    { name = "OIDC_AUDIENCE", value = local.oidc_audience },
    { name = "OIDC_JWKS_URI", value = var.oidc_jwks_uri },
    { name = "OIDC_GROUP_CLAIM", value = var.oidc_group_claim },
    { name = "ALLOWED_GROUPS", value = join(",", var.oidc_allowed_groups) },
    { name = "ALLOWED_ORIGINS", value = local.site_origin },
    { name = "WEBAPP_CONFIG", value = local.webapp_config_json },
    { name = "CONTENT_SECURITY_POLICY", value = local.content_security_policy },
    { name = "CSP_REPORT_ONLY", value = local.csp_report_only },
    { name = "BEDROCK_REGION", value = var.ai_region },
    { name = "NOVA_MODEL_ID", value = var.nova_sonic_model_id },
    { name = "TRANSCRIBE_REGION", value = var.ai_region },
    { name = "TRANSLATE_REGION", value = var.ai_region },
    { name = "POLLY_REGION", value = var.ai_region },
    # 100 s: ECS allows 120 s between SIGTERM and SIGKILL; leave 20 s for cleanup
    { name = "DRAIN_TIMEOUT_MS", value = "100000" },
    # With both sides on backup each sentence is one Translate + Polly request
    { name = "FALLBACK_REQUESTS_PER_MINUTE", value = "150" },
    { name = "FORCE_BACKUP_PARAMETER", value = "${var.ssm_hierarchy}forceBackupTranslation" },
    { name = "SSM_REGION", value = var.aws_region },
  ]
  # TEST_SIGN_IN_PARAMETER only when the feature is enabled
  container_env_test_sign_in = var.test_sign_in ? [
    { name = "TEST_SIGN_IN_PARAMETER", value = local.test_sign_in_parameter_name }
  ] : []

  container_environment = concat(local.container_env_base, local.container_env_test_sign_in)
}
