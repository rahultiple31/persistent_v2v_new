mock_provider "aws" {}

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
      local.function_properties.FunctionName == "SNOW_btsgsd-dev" &&
      local.function_properties.Runtime == "python3.14" &&
      local.function_properties.Architectures == ["x86_64"] &&
      local.function_properties.Handler == "lambda_function.lambda_handler" &&
      local.function_properties.MemorySize == 512 &&
      local.function_properties.Timeout == 8 &&
      local.function_properties.EphemeralStorage.Size == 512 &&
      local.function_properties.PackageType == "Zip" &&
      local.function_properties.ReservedConcurrentExecutions == 300 &&
      local.function_properties.SnapStart.ApplyOn == "PublishedVersions" &&
      local.function_properties.RuntimeManagementConfig.UpdateRuntimeOn == "Auto" &&
      aws_cloudwatch_log_group.snow.name == "/aws/lambda/SNOW_btsgsd-dev"
    )
    error_message = "Preserve all requested Lambda settings, including reserved concurrency 300."
  }

  assert {
    condition = (
      jsondecode(aws_cloudformation_stack.snow.template_body).Resources[local.version_logical_id].Type == "AWS::Lambda::Version" &&
      jsondecode(aws_cloudformation_stack.snow.template_body).Resources[local.version_logical_id].Properties.CodeSha256.Ref == "CodeHash" &&
      jsondecode(aws_cloudformation_stack.snow.template_body).Outputs.VersionArn.Value.Ref == local.version_logical_id &&
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
  expect_failures = [aws_cloudformation_stack.snow]
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
      local.function_properties.Environment.Variables.SN_INSTANCE == "https://example.service-now.com" &&
      local.function_properties.Environment.Variables.SN_SECRET_NAME == "dev/snow/credentials"
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
    condition     = length(data.external.capacity) == 0 && !contains(keys(local.function_properties), "ReservedConcurrentExecutions")
    error_message = "A null reservation must omit ReservedConcurrentExecutions and skip the capacity check."
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
    condition     = local.function_properties.ReservedConcurrentExecutions == 50
    error_message = "Use the configured reserved concurrency."
  }
}
