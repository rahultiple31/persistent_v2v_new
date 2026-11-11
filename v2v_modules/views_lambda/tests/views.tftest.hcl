mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "518902362956"
    }
  }

  mock_data "aws_security_group" {
    defaults = {
      id = "sg-0aaaaaaaaaaaaaaaa"
    }
  }

  mock_data "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::518902362956:role/BTSGSD-IVA-Lambda-Warmup-Scheduler-Role"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::518902362956:role/BTSGSD-V2V-US-views-role"
    }
  }

  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-east-1:518902362956:log-group:/aws/lambda/BTSGSD-V2V-US-views"
    }
  }

  mock_resource "aws_lambda_function" {
    defaults = {
      arn = "arn:aws:lambda:us-east-1:518902362956:function:BTSGSD-V2V-US-views"
    }
  }
}

mock_provider "time" {}
mock_provider "archive" {}

variables {
  function_name            = "BTSGSD-V2V-US-views"
  connect_instance_arn     = "arn:aws:connect:us-east-1:518902362956:instance/bcc989e5-cd9d-494f-9cd4-434f39ccc90e"
  vpc_id                   = "vpc-0bbbbbbbbbbbbbbbb"
  subnet_ids               = ["subnet-0cccccccccccccccc", "subnet-0dddddddddddddddd"]
  security_group_ids       = ["sg-0eeeeeeeeeeeeeeee"]
  core_security_group_name = "BTSGSD-V2V-US-LAMBDA-core-sg"
}

run "function_matches_the_deployed_views_lambda" {
  command = apply

  assert {
    condition = (
      aws_lambda_function.this.function_name == "BTSGSD-V2V-US-views" &&
      aws_lambda_function.this.handler == "warmup_wrapper.handler" &&
      aws_lambda_function.this.runtime == "python3.13" &&
      aws_lambda_function.this.memory_size == 256 &&
      aws_lambda_function.this.timeout == 10 &&
      aws_lambda_function.this.tracing_config[0].mode == "Active" &&
      aws_lambda_function.this.reserved_concurrent_executions == -1 &&
      aws_lambda_function.this.environment[0].variables.ORIGINAL_HANDLER == "lambda_function.lambda_handler" &&
      aws_lambda_function.this.environment[0].variables.POLL_SLEEP == "4"
    )
    error_message = "The function must keep the deployed handler, memory, timeout, tracing and polling settings."
  }

  assert {
    condition = (
      aws_lambda_function.this.environment[0].variables.CONNECT_INSTANCE_ID == "bcc989e5-cd9d-494f-9cd4-434f39ccc90e" &&
      aws_connect_lambda_function_association.this.instance_id == "bcc989e5-cd9d-494f-9cd4-434f39ccc90e"
    )
    error_message = "The Connect instance ID must come from connect_instance_arn, never a literal."
  }

  assert {
    condition = (
      aws_lambda_function.this.environment[0].variables.AWS_LAMBDA_EXEC_WRAPPER == "/opt/otel-instrument" &&
      length(aws_lambda_function.this.layers) == 1
    )
    error_message = "Application Signals must be enabled through the shared layer, as on the deployed function."
  }
}

run "function_runs_in_the_lambda_vpc" {
  command = apply

  assert {
    condition = (
      toset(aws_lambda_function.this.vpc_config[0].subnet_ids) == toset(var.subnet_ids) &&
      toset(aws_lambda_function.this.vpc_config[0].security_group_ids) == toset(["sg-0eeeeeeeeeeeeeeee", "sg-0aaaaaaaaaaaaaaaa"]) &&
      data.aws_security_group.lambda_core.name == "BTSGSD-V2V-US-LAMBDA-core-sg" &&
      data.aws_security_group.lambda_core.vpc_id == "vpc-0bbbbbbbbbbbbbbbb"
    )
    error_message = "The function must use the given subnets, the extra security group and the core Lambda security group."
  }
}

run "role_grants_only_logs_and_describe_contact" {
  command = apply

  assert {
    condition = (
      jsondecode(aws_iam_role_policy.execution.policy).Statement[0].Action == ["logs:CreateLogStream", "logs:PutLogEvents"] &&
      jsondecode(aws_iam_role_policy.execution.policy).Statement[1].Action == ["connect:DescribeContact"] &&
      jsondecode(aws_iam_role_policy.execution.policy).Statement[1].Resource == [
        "arn:aws:connect:us-east-1:518902362956:instance/bcc989e5-cd9d-494f-9cd4-434f39ccc90e",
        "arn:aws:connect:us-east-1:518902362956:instance/bcc989e5-cd9d-494f-9cd4-434f39ccc90e/*",
      ] &&
      length(jsondecode(aws_iam_role_policy.execution.policy).Statement) == 2
    )
    error_message = "The execution role may only write its logs and call DescribeContact on the Connect instance."
  }

  assert {
    condition = (
      aws_cloudwatch_log_group.this.name == "/aws/lambda/BTSGSD-V2V-US-views" &&
      aws_cloudwatch_log_group.this.retention_in_days == 14
    )
    error_message = "The function must log to /aws/lambda/<name> with 14-day retention."
  }
}

run "connect_may_invoke_the_function" {
  command = apply

  assert {
    condition = (
      aws_lambda_permission.connect.principal == "connect.amazonaws.com" &&
      aws_lambda_permission.connect.source_arn == var.connect_instance_arn &&
      aws_lambda_permission.connect.source_account == "518902362956" &&
      aws_lambda_permission.connect.action == "lambda:InvokeFunction"
    )
    error_message = "Only the given Connect instance in this account may invoke the function."
  }
}

run "hourly_warmup_schedule_matches_the_deployed_one" {
  command = apply

  assert {
    condition = (
      aws_scheduler_schedule.warmup.name == "BTSGSD-V2V-US-views-warmup" &&
      aws_scheduler_schedule.warmup.group_name == "default" &&
      aws_scheduler_schedule.warmup.schedule_expression == "rate(1 hour)" &&
      aws_scheduler_schedule.warmup.state == "ENABLED" &&
      aws_scheduler_schedule.warmup.flexible_time_window[0].mode == "OFF" &&
      aws_scheduler_schedule.warmup.target[0].arn == aws_lambda_function.this.arn &&
      aws_scheduler_schedule.warmup.target[0].role_arn == data.aws_iam_role.warmup_scheduler.arn &&
      data.aws_iam_role.warmup_scheduler.name == "BTSGSD-IVA-Lambda-Warmup-Scheduler-Role" &&
      aws_scheduler_schedule.warmup.target[0].input == jsonencode({ warmup = true }) &&
      aws_scheduler_schedule.warmup.target[0].retry_policy[0].maximum_event_age_in_seconds == 86400 &&
      aws_scheduler_schedule.warmup.target[0].retry_policy[0].maximum_retry_attempts == 185
    )
    error_message = "Warm the function hourly with the warm-up payload, a one-day retry window and 185 retries."
  }

  assert {
    condition = (
      aws_iam_role_policy.warmup_scheduler_invoke.name == "BTSGSD-V2V-US-views-warmup-invoke" &&
      aws_iam_role_policy.warmup_scheduler_invoke.role == data.aws_iam_role.warmup_scheduler.name &&
      jsondecode(aws_iam_role_policy.warmup_scheduler_invoke.policy).Statement[0].Action == ["lambda:InvokeFunction"] &&
      jsondecode(aws_iam_role_policy.warmup_scheduler_invoke.policy).Statement[0].Resource == aws_lambda_function.this.arn
    )
    error_message = "The scheduler role may invoke only this function."
  }
}

run "reject_empty_subnet_list" {
  command = plan

  variables {
    subnet_ids = []
  }

  expect_failures = [var.subnet_ids]
}

run "reject_poll_sleep_not_below_timeout" {
  command = plan

  variables {
    poll_sleep_seconds = 10
  }

  expect_failures = [var.poll_sleep_seconds]
}
