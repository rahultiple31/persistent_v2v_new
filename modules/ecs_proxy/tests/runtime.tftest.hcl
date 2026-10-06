mock_provider "aws" {}
variables {
  name_prefix                    = "test-proxy"
  aws_region                     = "us-east-1"
  container_image                = "123456789012.dkr.ecr.us-east-1.amazonaws.com/proxy:test"
  use_bootstrap_container        = false
  container_port                 = 8080
  desired_count                  = 2
  task_cpu                       = 512
  task_memory                    = 1024
  health_check_path              = "/healthz"
  cognito_user_pool_id           = "us-east-1_test"
  cognito_client_id              = "client"
  allowed_origins                = ["https://test.cloudfront.net"]
  allowed_groups                 = []
  force_backup_parameter         = "/test/forceBackupTranslation"
  bedrock_model_id               = "amazon.nova-2-sonic-v1:0"
  fallback_rate_limit_per_minute = 150
  max_connections_per_user       = 12
  task_execution_role_arn        = "arn:aws:iam::123456789012:role/execution"
  task_role_arn                  = "arn:aws:iam::123456789012:role/proxy"
  proxy_log_group_name           = "/ecs/test"
  service_security_group_id      = "sg-1234567890abcdef0"
  private_subnet_ids             = ["subnet-1234567890abcdef0", "subnet-1234567890abcdef1"]
  target_group_arn               = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/proxy/1234567890abcdef"
}
run "nova_startup_contract" {
  command = plan
  assert {
    condition     = !can(jsondecode(aws_ecs_task_definition.proxy.container_definitions)[0].command)
    error_message = "The real image must run its own entrypoint, without a bootstrap command."
  }
  assert {
    condition     = alltrue([for name in ["COGNITO_USER_POOL_ID", "COGNITO_CLIENT_ID", "ALLOWED_ORIGINS", "BEDROCK_REGION", "NOVA_MODEL_ID", "FALLBACK_REQUESTS_PER_MINUTE"] : contains([for item in jsondecode(aws_ecs_task_definition.proxy.container_definitions)[0].environment : item.name], name)])
    error_message = "ECS must supply all required Nova runtime configuration names."
  }
  assert {
    condition     = jsondecode(aws_ecs_task_definition.proxy.container_definitions)[0].stopTimeout == 120
    error_message = "ECS must allow time to drain active streams."
  }
}
run "reject_missing_authentication" {
  command = plan
  variables {
    cognito_user_pool_id = ""
  }
  expect_failures = [aws_ecs_task_definition.proxy]
}
