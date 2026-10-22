mock_provider "aws" {
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::518902362956:role/lambda-test-role"
    }
  }
}

mock_provider "external" {
  mock_data "external" {
    defaults = {
      result = {
        unreserved          = "200"
        current_reservation = "0"
        maximum_reservation = "100"
      }
    }
  }
}

run "requested_lambda_configuration" {
  command = plan

  assert {
    condition = (
      aws_lambda_function.interaction.function_name == "BTSGSD-V2V-US-ServiceNow_Interaction" &&
      aws_lambda_function.interaction.runtime == "python3.14" &&
      aws_lambda_function.interaction.architectures == tolist(["x86_64"]) &&
      aws_lambda_function.interaction.handler == "lambda_function.lambda_handler" &&
      aws_lambda_function.interaction.memory_size == 512 &&
      aws_lambda_function.interaction.timeout == 8 &&
      aws_lambda_function.interaction.ephemeral_storage[0].size == 512 &&
      aws_lambda_function.interaction.reserved_concurrent_executions == 100 &&
      aws_lambda_function.interaction.logging_config[0].log_group == "/aws/lambda/BTSGSD-V2V-US-ServiceNow_Interaction" &&
      aws_lambda_function.interaction.logging_config[0].log_group == aws_cloudwatch_log_group.interaction.name &&
      data.archive_file.interaction.source_dir == "./src" &&
      aws_lambda_function.interaction.s3_bucket == null && aws_lambda_function.interaction.s3_key == null
    )
    error_message = "Deploy the requested runtime, architecture, handler, capacity and custom logging configuration using the source ZIP."
  }

  assert {
    condition = (
      aws_lambda_function.interaction.filename == data.archive_file.interaction.output_path &&
      aws_lambda_function.interaction.source_code_hash == data.archive_file.interaction.output_base64sha256 &&
      aws_lambda_function.interaction.environment[0].variables.SN_INSTANCE == "abbvienowdev" &&
      aws_lambda_function.interaction.environment[0].variables.SN_CTI_RULE == "cti_gsd" &&
      !aws_lambda_function.interaction.publish
    )
    error_message = "Upload the local ZIP directly, preserve handler defaults, and avoid publishing extra versions."
  }
}

run "environment_override_preserves_other_defaults" {
  command = plan

  variables {
    environment_variables = { SN_INSTANCE = "exampledev" }
  }

  assert {
    condition = (
      aws_lambda_function.interaction.environment[0].variables.SN_INSTANCE == "exampledev" &&
      aws_lambda_function.interaction.environment[0].variables.SN_CTI_RULE == "cti_gsd"
    )
    error_message = "An instance override must retain the CTI rule default."
  }
}

run "insufficient_concurrency_is_rejected" {
  command = plan

  override_data {
    target = data.external.capacity[0]
    values = {
      result = {
        unreserved          = "199"
        current_reservation = "0"
        maximum_reservation = "99"
      }
    }
  }

  expect_failures = [aws_lambda_function.interaction]
}

run "unreserved_pool_omits_reservation_and_capacity_check" {
  command = plan

  variables {
    reserved_concurrency = null
  }

  assert {
    condition = (
      length(data.external.capacity) == 0 &&
      aws_lambda_function.interaction.reserved_concurrent_executions == -1
    )
    error_message = "null must use the unreserved pool and skip the capacity checker entirely."
  }
}

run "custom_reservation_uses_its_own_capacity_threshold" {
  command = plan

  variables {
    reserved_concurrency = 50
  }

  override_data {
    target = data.external.capacity[0]
    values = {
      result = {
        unreserved          = "150"
        current_reservation = "0"
        maximum_reservation = "50"
      }
    }
  }

  assert {
    condition = (
      length(data.external.capacity) == 1 &&
      aws_lambda_function.interaction.reserved_concurrent_executions == 50
    )
    error_message = "An explicit reservation of 50 must check and configure 50 rather than the default 100."
  }
}

run "zero_available_reservation_rejects_explicit_100" {
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

  expect_failures = [aws_lambda_function.interaction]
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
    reserved_concurrency = 50.5
  }

  expect_failures = [var.reserved_concurrency]
}

run "oversized_direct_upload_is_rejected" {
  command = plan

  override_data {
    target = data.archive_file.interaction
    values = {
      output_size = 50 * 1024 * 1024 + 1
    }
  }

  expect_failures = [aws_lambda_function.interaction]
}
