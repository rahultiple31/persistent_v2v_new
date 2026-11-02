mock_provider "aws" {}
mock_provider "aws" {
  alias = "us_east_1"
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_region" {
    defaults = { name = "us-east-1" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
}

variables {
  enabled_modules     = ["v2v"]
  translation_enabled = true
  proxy_enabled       = true
  sso_enabled         = false
}

run "standalone_v2v_without_proxy_state" {
  command = plan
  assert {
    condition     = length(data.terraform_remote_state.proxy) == 0
    error_message = "Standalone V2V must not read proxy state."
  }
  assert {
    condition     = length(module.s3_v2v) == 1 && length(module.cloudfront_v2v) == 1 && length(module.cognito_v2v) == 1 && length(module.iam_v2v) == 1 && length(module.ssm_v2v) == 1
    error_message = "Standalone V2V must still deploy the frontend and authentication stack."
  }
  assert {
    condition     = local.frontend_config.translationEnabled == "false" && local.frontend_config.proxyEnabled == "false" && local.ssm_parameters.translationEnabled == "false" && !module.iam_v2v[0].translation_policy_attached
    error_message = "An unconnected proxy must not enable browser translation or direct AWS permissions."
  }
  assert {
    condition     = output.connect_v2v_translation.translation_mode == "off" && !output.connect_v2v_translation.proxy_integration_enabled
    error_message = "V2V outputs must report the standalone translation state."
  }
}

run "direct_translation_without_proxy_state" {
  command = plan
  variables {
    proxy_enabled             = false
    proxy_integration_enabled = true
  }
  assert {
    condition     = length(data.terraform_remote_state.proxy) == 0 && local.frontend_config.translationEnabled == "true" && local.frontend_config.proxyEnabled == "false" && local.ssm_parameters.translationEnabled == "true" && module.iam_v2v[0].translation_policy_attached
    error_message = "Direct translation must retain authenticated AWS permissions without reading proxy state."
  }
  assert {
    condition     = output.connect_v2v_translation.translation_mode == "direct" && !output.connect_v2v_translation.proxy_integration_enabled
    error_message = "Direct translation must not report proxy integration as active."
  }
}

run "translation_off_with_integration_requested" {
  command = plan
  variables {
    translation_enabled       = false
    proxy_integration_enabled = true
  }
  assert {
    condition     = length(data.terraform_remote_state.proxy) == 0 && local.frontend_config.translationEnabled == "false" && local.frontend_config.proxyEnabled == "false" && !module.iam_v2v[0].translation_policy_attached
    error_message = "Disabling translation must suppress proxy integration and browser permissions."
  }
}

run "explicit_proxy_integration" {
  command = plan
  variables {
    proxy_integration_enabled = true
  }
  override_data {
    target = data.terraform_remote_state.proxy[0]
    values = {
      outputs = {
        regional_proxy = {
          "us-east-1" = {
            internal_alb_arn      = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/proxy/1234567890abcdef"
            internal_alb_dns_name = "internal-proxy.us-east-1.elb.amazonaws.com"
          }
        }
      }
    }
  }
  assert {
    condition     = length(data.terraform_remote_state.proxy) == 1 && local.frontend_config.translationEnabled == "true" && local.frontend_config.proxyEnabled == "true" && local.ssm_parameters.translationEnabled == "true" && !module.iam_v2v[0].translation_policy_attached
    error_message = "Explicit integration must enable proxy translation without direct browser permissions."
  }
  assert {
    condition     = output.connect_v2v_translation.translation_mode == "proxy" && output.connect_v2v_translation.proxy_integration_enabled
    error_message = "Integrated V2V must use the existing proxy instead of deploying its ALB."
  }
}
