mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "518902362956"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "us-east-1"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }

  mock_data "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::518902362956:role/BTSGSD-IVA-Lambda-Warmup-Scheduler-Role"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::518902362956:role/BTSGSD-V2V-US-UpdateSessionAttributes-role"
    }
  }

  mock_resource "aws_lambda_function" {
    defaults = {
      arn = "arn:aws:lambda:us-east-1:518902362956:function:BTSGSD-V2V-US-UpdateSessionAttributes"
    }
  }
}

mock_provider "time" {}

variables {
  function_name        = "BTSGSD-V2V-US-UpdateSessionAttributes"
  source_file          = "../../environments/v2v/metadata/scr_lambda/lambda_function.py"
  zip_path             = "./tests/warmup-test.zip"
  connect_instance_arn = "arn:aws:connect:us-east-1:518902362956:instance/bcc989e5-cd9d-494f-9cd4-434f39ccc90e"
  assistant_id         = "160889f7-d564-47fb-97db-94549fc55993"
}

run "warmup_schedule_configuration" {
  command = apply

  assert {
    condition = (
      aws_scheduler_schedule.warmup.name == "BTSGSD-V2V-US-UpdateSessionAttributes-warmup" &&
      aws_scheduler_schedule.warmup.group_name == "default" &&
      aws_scheduler_schedule.warmup.schedule_expression == "rate(5 minutes)" &&
      aws_scheduler_schedule.warmup.state == "ENABLED" &&
      aws_scheduler_schedule.warmup.flexible_time_window[0].mode == "OFF" &&
      aws_scheduler_schedule.warmup.target[0].arn == aws_lambda_function.this.arn &&
      aws_scheduler_schedule.warmup.target[0].role_arn == data.aws_iam_role.warmup_scheduler.arn &&
      data.aws_iam_role.warmup_scheduler.name == "BTSGSD-IVA-Lambda-Warmup-Scheduler-Role" &&
      aws_scheduler_schedule.warmup.target[0].input == jsonencode({ warmup = true }) &&
      aws_scheduler_schedule.warmup.target[0].retry_policy[0].maximum_event_age_in_seconds == 86400 &&
      aws_scheduler_schedule.warmup.target[0].retry_policy[0].maximum_retry_attempts == 185
    )
    error_message = "Warm the selected Lambda every five minutes with the specified existing role, payload, one-day retention, and 185 retries."
  }

  assert {
    condition = (
      aws_iam_role_policy.warmup_scheduler_invoke.role == data.aws_iam_role.warmup_scheduler.name &&
      jsondecode(aws_iam_role_policy.warmup_scheduler_invoke.policy).Statement[0].Effect == "Allow" &&
      jsondecode(aws_iam_role_policy.warmup_scheduler_invoke.policy).Statement[0].Action == ["lambda:InvokeFunction"] &&
      jsondecode(aws_iam_role_policy.warmup_scheduler_invoke.policy).Statement[0].Resource == aws_lambda_function.this.arn &&
      aws_lambda_function.this.handler == "warmup_wrapper.handler" &&
      aws_lambda_function.this.environment[0].variables.ORIGINAL_HANDLER == "lambda_function.handler"
    )
    error_message = "Grant the existing scheduler role invocation of this Lambda and keep the warm-up wrapper as the entry point."
  }
}
