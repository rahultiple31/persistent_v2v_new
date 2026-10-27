mock_provider "aws" {
  mock_data "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::518902362956:role/SNOW_btsgsd-dev-lambda-role"
    }
  }

  mock_resource "aws_lambda_function" {
    defaults = {
      arn = "arn:aws:lambda:us-east-1:518902362956:function:BTSGSD-V2V-US-SNOW"
    }
  }
}

mock_provider "external" {}

variables {
  reserved_concurrency = null
}

override_data {
  target = data.aws_iam_role.warmup_scheduler
  values = {
    arn = "arn:aws:iam::518902362956:role/BTSGSD-IVA-Lambda-Warmup-Scheduler-Role"
  }
}

run "hourly_snow_warmup" {
  command = apply

  assert {
    condition = (
      aws_scheduler_schedule.warmup.name == "BTSGSD-V2V-US-SNOW-warmup" &&
      aws_scheduler_schedule.warmup.group_name == "default" &&
      aws_scheduler_schedule.warmup.schedule_expression == "rate(1 hour)" &&
      aws_scheduler_schedule.warmup.state == "ENABLED" &&
      aws_scheduler_schedule.warmup.flexible_time_window[0].mode == "OFF" &&
      aws_scheduler_schedule.warmup.target[0].arn == aws_lambda_function.snow.arn &&
      aws_lambda_function.snow.function_name == "BTSGSD-V2V-US-SNOW" &&
      aws_scheduler_schedule.warmup.target[0].role_arn == "arn:aws:iam::518902362956:role/BTSGSD-IVA-Lambda-Warmup-Scheduler-Role" &&
      data.aws_iam_role.warmup_scheduler.name == "BTSGSD-IVA-Lambda-Warmup-Scheduler-Role" &&
      aws_scheduler_schedule.warmup.target[0].input == jsonencode({ warmup = true }) &&
      aws_scheduler_schedule.warmup.target[0].retry_policy[0].maximum_event_age_in_seconds == 86400 &&
      aws_scheduler_schedule.warmup.target[0].retry_policy[0].maximum_retry_attempts == 185
    )
    error_message = "Schedule the selected SNOW Lambda hourly using the requested role, warm-up payload, one-day retention, and 185 retries."
  }

  assert {
    condition = (
      aws_iam_role_policy.warmup_scheduler_invoke.role == data.aws_iam_role.warmup_scheduler.name &&
      jsondecode(aws_iam_role_policy.warmup_scheduler_invoke.policy).Statement[0].Effect == "Allow" &&
      jsondecode(aws_iam_role_policy.warmup_scheduler_invoke.policy).Statement[0].Action == ["lambda:InvokeFunction"] &&
      jsondecode(aws_iam_role_policy.warmup_scheduler_invoke.policy).Statement[0].Resource == aws_lambda_function.snow.arn &&
      aws_lambda_function.snow.handler == "warmup_wrapper.handler" &&
      aws_lambda_function.snow.environment[0].variables.ORIGINAL_HANDLER == "lambda_function.lambda_handler" &&
      length(data.external.capacity) == 0 &&
      aws_lambda_function.snow.reserved_concurrent_executions == -1
    )
    error_message = "Limit Scheduler invocation to SNOW and preserve its warm-up entry point and unreserved concurrency option."
  }
}
