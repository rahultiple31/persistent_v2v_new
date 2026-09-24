output "regional_connect_instances" {
  description = "Amazon Connect deployment outputs by region."
  value = {
    "us-east-1" = {
      region             = "us-east-1"
      instance_id        = try(module.connect_us_east_1[0].instance_id, null)
      instance_arn       = try(module.connect_us_east_1[0].instance_arn, null)
      queue_id           = try(module.connect_us_east_1[0].queue_id, null)
      routing_profile_id = try(module.connect_us_east_1[0].routing_profile_id, null)
      admin_user_id      = try(module.connect_us_east_1[0].admin_user_id, null)
    }
  }
}

output "regional_lambda_functions" {
  description = "Disposable Lambda test function outputs by region."
  value = {
    "us-east-1" = {
      region        = "us-east-1"
      function_name = try(module.lambda_us_east_1[0].function_name, null)
      function_arn  = try(module.lambda_us_east_1[0].function_arn, null)
      invoke_arn    = try(module.lambda_us_east_1[0].invoke_arn, null)
      role_arn      = try(module.lambda_us_east_1[0].role_arn, null)
    }
  }
}

output "connect_v2v_translation" {
  description = "Amazon Connect V2V translation solution outputs."
  value = {
    backend_region                      = data.aws_region.current.name
    identity_pool_id                    = try(module.cognito_v2v[0].identity_pool_id, null)
    user_pool_id                        = try(module.cognito_v2v[0].user_pool_id, null)
    user_pool_web_client_id             = try(module.cognito_v2v[0].user_pool_web_client_id, null)
    cognito_domain_url                  = try(module.cognito_v2v[0].cognito_domain_url, null)
    authenticated_role_arn              = try(module.iam_v2v[0].authenticated_role_arn, null)
    unauthenticated_role_arn            = try(module.iam_v2v[0].unauthenticated_role_arn, null)
    v2v_bucket_name                     = try(module.s3_v2v[0].v2v_bucket_name, null)
    v2v_log_bucket_name                 = try(module.s3_v2v[0].v2v_log_bucket_name, null)
    cloudfront_distribution_id          = try(module.cloudfront_v2v[0].cloudfront_distribution_id, null)
    cloudfront_distribution_domain_name = try(module.cloudfront_v2v[0].cloudfront_distribution_domain_name, null)
    v2v_url                             = try(module.cloudfront_v2v[0].v2v_url, null)
    ssm_parameter_names                 = try(module.ssm_v2v[0].parameter_names, {})
  }
}
