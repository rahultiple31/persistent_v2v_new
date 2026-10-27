mock_provider "aws" {
  mock_resource "aws_lambda_function" {
    defaults = {
      arn = "arn:aws:lambda:us-east-1:518902362956:function:BTSGSD-V2V-US-Nextthink_Handoff"
    }
  }

  mock_data "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::518902362956:role/Nextthink_Handoff_btsgsd-dev-role"
    }
  }
  mock_data "aws_secretsmanager_secret" {
    defaults = {
      arn = "arn:aws:secretsmanager:us-east-1:518902362956:secret:Nextthink/Clientid/Secretkey-abcdef"
    }
  }

  mock_data "aws_region" {
    defaults = {
      name   = "us-east-1"
      region = "us-east-1"
    }
  }

}

mock_provider "external" {
  mock_data "external" {
    defaults = {
      result = {
        unreserved          = "300"
        current_reservation = "0"
        maximum_reservation = "200"
      }
    }
  }
}

override_data {
  target = data.aws_iam_role.warmup_scheduler
  values = {
    arn = "arn:aws:iam::518902362956:role/BTSGSD-IVA-Lambda-Warmup-Scheduler-Role"
  }
}

run "requested_lambda_configuration" {
  command = plan

  assert {
    condition = (
      aws_lambda_function.handoff.function_name == "BTSGSD-V2V-US-Nextthink_Handoff" &&
      aws_lambda_function.handoff.role == "arn:aws:iam::518902362956:role/Nextthink_Handoff_btsgsd-dev-role" &&
      aws_lambda_function.handoff.runtime == "python3.13" &&
      aws_lambda_function.handoff.architectures == tolist(["x86_64"]) &&
      aws_lambda_function.handoff.handler == "warmup_wrapper.handler" &&
      aws_lambda_function.handoff.environment[0].variables.ORIGINAL_HANDLER == "lambda_function.lambda_handler" &&
      aws_lambda_function.handoff.memory_size == 128 &&
      aws_lambda_function.handoff.timeout == 8 &&
      aws_lambda_function.handoff.reserved_concurrent_executions == 200 &&
      aws_lambda_function.handoff.environment[0].variables.NEXTHINK_SECRET_NAME == "Nextthink/Clientid/Secretkey" &&
      aws_lambda_function.handoff.logging_config[0].log_group == "/aws/lambda/BTSGSD-V2V-US-Nextthink_Handoff" &&
      aws_lambda_function.handoff.logging_config[0].log_group == aws_cloudwatch_log_group.handoff.name &&
      aws_lambda_function.handoff.source_code_hash == data.archive_file.handoff.output_base64sha256 &&
      data.archive_file.handoff.source_dir == "./src" &&
      aws_lambda_function.handoff.s3_bucket == null && aws_lambda_function.handoff.s3_key == null
    )
    error_message = "Deploy the requested Lambda configuration with its source ZIP, secret name, and custom log group."
  }
}

run "secret_access_is_scoped" {
  command = apply

  assert {
    condition = (
      data.aws_secretsmanager_secret.credentials.name == "Nextthink/Clientid/Secretkey" &&
      length(jsondecode(aws_iam_role_policy.execution.policy).Statement) == 2 &&
      jsondecode(aws_iam_role_policy.execution.policy).Statement[1].Action == ["secretsmanager:GetSecretValue"] &&
      jsondecode(aws_iam_role_policy.execution.policy).Statement[1].Resource == data.aws_secretsmanager_secret.credentials.arn
    )
    error_message = "Grant access only to the named secret; do not grant KMS access without a configured key."
  }
}

run "kms_access_and_environment_overrides" {
  command = apply

  variables {
    secret_kms_key_arn = "arn:aws:kms:us-east-1:518902362956:key/12345678-1234-1234-1234-123456789012"
    environment_variables = {
      NEXTHINK_SECRET_NAME = "must-not-replace-required-secret"
      READ_TIMEOUT_SECONDS = "1"
      ORIGINAL_HANDLER     = "warmup_wrapper.handler"
    }
  }

  assert {
    condition = (
      length(jsondecode(aws_iam_role_policy.execution.policy).Statement) == 3 &&
      jsondecode(aws_iam_role_policy.execution.policy).Statement[2].Action == ["kms:Decrypt"] &&
      jsondecode(aws_iam_role_policy.execution.policy).Statement[2].Resource == var.secret_kms_key_arn &&
      jsondecode(aws_iam_role_policy.execution.policy).Statement[2].Condition.StringEquals["kms:ViaService"] == "secretsmanager.us-east-1.amazonaws.com" &&
      jsondecode(aws_iam_role_policy.execution.policy).Statement[2].Condition.StringEquals["kms:EncryptionContext:SecretARN"] == data.aws_secretsmanager_secret.credentials.arn &&
      aws_lambda_function.handoff.environment[0].variables.NEXTHINK_SECRET_NAME == "Nextthink/Clientid/Secretkey" &&
      aws_lambda_function.handoff.environment[0].variables.READ_TIMEOUT_SECONDS == "1" &&
      aws_lambda_function.handoff.environment[0].variables.ORIGINAL_HANDLER == "lambda_function.lambda_handler"
    )
    error_message = "KMS decryption must be limited to the configured key and secret; preserve the required secret name when adding overrides."
  }
}

run "insufficient_concurrency_is_rejected" {
  command = plan

  override_data {
    target = data.external.capacity[0]
    values = {
      result = {
        unreserved          = "299"
        current_reservation = "0"
        maximum_reservation = "199"
      }
    }
  }

  expect_failures = [aws_lambda_function.handoff]
}

run "unreserved_pool_omits_reservation_and_capacity_check" {
  command = plan

  variables {
    reserved_concurrency = null
  }

  assert {
    condition = (
      length(data.external.capacity) == 0 &&
      aws_lambda_function.handoff.reserved_concurrent_executions == -1 &&
      aws_lambda_function.handoff.environment[0].variables.NEXTHINK_SECRET_NAME == "Nextthink/Clientid/Secretkey"
    )
    error_message = "null must use the unreserved pool and skip the capacity checker while preserving the required secret name."
  }
}

run "custom_reservation_uses_its_own_capacity_threshold" {
  command = plan

  variables {
    reserved_concurrency = 100
  }

  override_data {
    target = data.external.capacity[0]
    values = {
      result = {
        unreserved          = "200"
        current_reservation = "0"
        maximum_reservation = "100"
      }
    }
  }

  assert {
    condition = (
      length(data.external.capacity) == 1 &&
      aws_lambda_function.handoff.reserved_concurrent_executions == 100
    )
    error_message = "An explicit reservation must check and configure its requested amount instead of the default 200."
  }
}

run "zero_available_reservation_rejects_explicit_200" {
  command = plan

  override_data {
    target = data.external.capacity[0]
    values = {
      result = {
        unreserved          = "100"
        current_reservation = "0"
        maximum_reservation = "0"
      }
    }
  }

  expect_failures = [aws_lambda_function.handoff]
}

run "zero_reservation_is_rejected" {
  command = plan

  variables {
    reserved_concurrency = 0
  }

  expect_failures = [var.reserved_concurrency]
}

run "fractional_reservation_is_rejected" {
  command = plan

  variables {
    reserved_concurrency = 100.5
  }

  expect_failures = [var.reserved_concurrency]
}

run "oversized_direct_upload_is_rejected" {
  command = plan

  override_data {
    target = data.archive_file.handoff
    values = {
      output_size = 50 * 1024 * 1024 + 1
    }
  }

  expect_failures = [aws_lambda_function.handoff]
}

mock_provider "time" {}
