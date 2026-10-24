mock_provider "aws" {
  mock_data "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::518902362956:role/SNOW_btsgsd-dev-lambda-role"
    }
  }
}

mock_provider "external" {
  mock_data "external" {
    defaults = {
      result = {
        unreserved          = "400"
        current_reservation = "0"
        maximum_reservation = "300"
      }
    }
  }
}

run "requested_configuration_and_published_version" {
  command = plan

  assert {
    condition = (
      aws_lambda_function.snow.function_name == "BTSGSD-V2V-US-SNOW" &&
      aws_lambda_function.snow.runtime == "python3.14" &&
      aws_lambda_function.snow.architectures == tolist(["x86_64"]) &&
      aws_lambda_function.snow.handler == "lambda_function.lambda_handler" &&
      aws_lambda_function.snow.memory_size == 512 &&
      aws_lambda_function.snow.timeout == 8 &&
      aws_lambda_function.snow.ephemeral_storage[0].size == 512 &&
      aws_lambda_function.snow.package_type == "Zip" &&
      aws_lambda_function.snow.reserved_concurrent_executions == 300 &&
      aws_lambda_function.snow.snap_start[0].apply_on == "PublishedVersions" &&
      aws_lambda_runtime_management_config.snow.update_runtime_on == "Auto" &&
      aws_cloudwatch_log_group.snow.name == "/aws/lambda/BTSGSD-V2V-US-SNOW"
    )
    error_message = "Preserve all requested Lambda settings, including reserved concurrency 300."
  }

  assert {
    condition = (
      aws_lambda_function.snow.publish &&
      aws_lambda_function.snow.source_code_hash == data.archive_file.snow.output_base64sha256 &&
      aws_lambda_function.snow.filename == data.archive_file.snow.output_path &&
      data.archive_file.snow.output_path == "./metadata/lambda-snow-btsgsd-dev/BTSGSD-V2V-US-SNOW.zip" &&
      data.archive_file.snow.source_dir == "./src"
    )
    error_message = "Package ./src and publish its exact ZIP hash for SnapStart."
  }
}

run "insufficient_capacity_stops_plan" {
  command = plan
  override_data {
    target = data.external.capacity
    values = {
      result = {
        unreserved          = "399"
        current_reservation = "0"
        maximum_reservation = "299"
      }
    }
  }
  expect_failures = [aws_lambda_function.snow]
}

run "existing_reservation_can_be_retained" {
  command = plan
  override_data {
    target = data.external.capacity
    values = {
      result = {
        unreserved          = "100"
        current_reservation = "300"
        maximum_reservation = "300"
      }
    }
  }
}

run "servicenow_environment_configuration" {
  command = plan
  variables {
    environment_variables = {
      SN_INSTANCE    = "https://example.service-now.com"
      SN_SECRET_NAME = "dev/snow/credentials"
    }
  }
  assert {
    condition = (
      aws_lambda_function.snow.environment[0].variables.SN_INSTANCE == "https://example.service-now.com" &&
      aws_lambda_function.snow.environment[0].variables.SN_SECRET_NAME == "dev/snow/credentials"
    )
    error_message = "Pass the ServiceNow instance and secret name to the handler."
  }
}

run "no_reservation_skips_capacity_check" {
  command = plan
  variables {
    reserved_concurrency = null
  }
  assert {
    condition     = length(data.external.capacity) == 0 && aws_lambda_function.snow.reserved_concurrent_executions == -1
    error_message = "A null reservation must use the unreserved pool and skip the capacity check."
  }
}

run "lower_reservation_within_capacity" {
  command = plan
  variables {
    reserved_concurrency = 50
  }
  override_data {
    target = data.external.capacity
    values = {
      result = {
        unreserved          = "150"
        current_reservation = "0"
        maximum_reservation = "50"
      }
    }
  }
  assert {
    condition     = aws_lambda_function.snow.reserved_concurrent_executions == 50
    error_message = "Use the configured reserved concurrency."
  }
}

run "oversized_direct_upload_is_rejected" {
  command = plan

  override_data {
    target = data.archive_file.snow
    values = {
      output_size = 50 * 1024 * 1024 + 1
    }
  }

  expect_failures = [aws_lambda_function.snow]
}
