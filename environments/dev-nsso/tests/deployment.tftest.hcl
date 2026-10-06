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
mock_provider "aws" {
  alias = "proxy_us_east_1"
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_availability_zones" {
    defaults = { names = ["us-east-1a", "us-east-1b"] }
  }
  mock_data "aws_availability_zone" {
    defaults = { zone_id = "use1-az1" }
  }
}

variables {
  enabled_modules       = ["v2v"]
  translation_enabled   = true
  proxy_enabled         = true
  proxy_runtime_enabled = false
  proxy_container_image = null
  sso_enabled           = false
}

run "standalone_v2v_without_proxy_state" {
  command = plan
  assert {
    condition     = length(data.terraform_remote_state.proxy) == 0 && length(data.terraform_remote_state.v2v) == 0
    error_message = "Standalone V2V must not read either remote state."
  }
  assert {
    condition     = length(module.s3_v2v) == 1 && length(module.cloudfront_v2v) == 1 && length(module.cognito_v2v) == 1 && length(module.iam_v2v) == 1 && length(module.ssm_v2v) == 1
    error_message = "Standalone V2V must still deploy the frontend and authentication stack."
  }
  assert {
    condition     = length(module.networking_proxy_us_east_1) == 0 && length(module.alb_proxy_us_east_1) == 0 && length(module.ecs_proxy_us_east_1) == 0
    error_message = "The V2V target must not deploy proxy infrastructure."
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

run "separate_proxy_bootstrap" {
  command = plan
  variables {
    enabled_modules = ["proxy"]
  }
  assert {
    condition     = length(module.networking_proxy_us_east_1) == 1 && length(module.alb_proxy_us_east_1) == 1 && length(module.ecs_proxy_us_east_1) == 1 && length(module.cloudfront_v2v) == 0
    error_message = "Disabling V2V integration must not disable a separate proxy deployment."
  }
  assert {
    condition     = length(data.terraform_remote_state.proxy) == 0 && length(data.terraform_remote_state.v2v) == 0 && !output.regional_proxy["us-east-1"].runtime_enabled
    error_message = "Proxy bootstrap must not require an activated V2V integration."
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
    condition     = output.connect_v2v_translation.translation_mode == "proxy" && output.connect_v2v_translation.proxy_integration_enabled && length(module.alb_proxy_us_east_1) == 0
    error_message = "Integrated V2V must use the existing proxy instead of deploying its ALB."
  }
}
