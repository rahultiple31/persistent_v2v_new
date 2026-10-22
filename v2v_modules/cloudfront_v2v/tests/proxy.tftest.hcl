mock_provider "aws" {}
variables {
  name_prefix                     = "test-v2v"
  app_name                        = "TestV2V"
  v2v_root_prefix                 = "V2VRoot/"
  v2v_bucket_regional_domain_name = "test.s3.us-east-1.amazonaws.com"
  v2v_log_bucket_domain_name      = "test-logs.s3.amazonaws.com"
  polly_region                    = "us-east-1"
  translate_region                = "us-east-1"
  polly_proxy_enabled             = false
  translate_proxy_enabled         = false
  proxy_enabled                   = true
  proxy_alb_arn                   = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/proxy/1234567890abcdef"
  proxy_alb_dns_name              = "internal-proxy.us-east-1.elb.amazonaws.com"
  translation_mode                = "proxy"
  cognito_domain_url              = "https://test.auth.us-east-1.amazoncognito.com"
  connect_instance_url            = "https://test.my.connect.aws"
  connect_instance_region         = "us-east-1"
}
run "standalone_without_proxy_alb" {
  command = plan
  variables {
    proxy_enabled      = false
    proxy_alb_arn      = ""
    proxy_alb_dns_name = ""
    translation_mode   = "off"
  }
  assert {
    condition     = length(aws_cloudfront_vpc_origin.proxy) == 0 && length(aws_cloudfront_distribution.v2v.ordered_cache_behavior) == 0
    error_message = "Standalone V2V must plan without ALB values or proxy routes."
  }
  assert {
    condition     = length(aws_cloudfront_distribution.v2v.origin) == 1 && one(aws_cloudfront_distribution.v2v.origin).origin_id == "v2v-s3"
    error_message = "Standalone V2V must still serve the webapp from its S3 origin."
  }
}
run "websocket_and_api_routes" {
  command = plan
  assert {
    condition     = toset([for behavior in aws_cloudfront_distribution.v2v.ordered_cache_behavior : behavior.path_pattern]) == toset(["/ws", "/api/*"])
    error_message = "Both Nova WebSocket and fallback API routes must reach the proxy."
  }
  assert {
    condition     = alltrue([for behavior in aws_cloudfront_distribution.v2v.ordered_cache_behavior : behavior.target_origin_id == "nova-proxy" && behavior.viewer_protocol_policy == "https-only" && !behavior.compress])
    error_message = "Proxy routes must require TLS and preserve streamed payloads."
  }
  assert {
    condition     = one(aws_cloudfront_response_headers_policy.security_headers.custom_headers_config[0].items).header == "Content-Security-Policy-Report-Only"
    error_message = "CSP must start in report-only mode."
  }
}
run "enforced_csp" {
  command = plan
  variables {
    csp_enforced = true
  }
  assert {
    condition     = strcontains(aws_cloudfront_response_headers_policy.security_headers.security_headers_config[0].content_security_policy[0].content_security_policy, "upgrade-insecure-requests")
    error_message = "Enforced CSP must include the configured security directives."
  }
}
run "reject_integration_without_proxy_alb" {
  command = plan
  variables {
    proxy_alb_arn      = ""
    proxy_alb_dns_name = ""
  }
  expect_failures = [aws_cloudfront_vpc_origin.proxy]
}
