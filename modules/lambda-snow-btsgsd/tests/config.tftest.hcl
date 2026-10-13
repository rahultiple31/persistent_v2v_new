mock_provider "aws" {}

variables {
  source_file = "../../environments/dev/metadata/snow_lambda/lambda_function_snow_btsgsd.py"
}

run "requested_snow_configuration" {
  command = plan

  assert {
    condition = (
      local.function_properties.FunctionName == "SNOW_btsgsd" &&
      local.function_properties.Runtime == "python3.14" &&
      local.function_properties.Architectures == ["x86_64"] &&
      local.function_properties.Handler == "lambda_function.lambda_handler" &&
      local.function_properties.MemorySize == 512 &&
      local.function_properties.Timeout == 8 &&
      local.function_properties.EphemeralStorage.Size == 512 &&
      local.function_properties.PackageType == "Zip" &&
      !contains(keys(jsondecode(aws_cloudformation_stack.snow.template_body).Resources.SNOWFunction.Properties), "ReservedConcurrentExecutions") &&
      local.function_properties.SnapStart.ApplyOn == "PublishedVersions" &&
      local.function_properties.RuntimeManagementConfig.UpdateRuntimeOn == "Auto" &&
      aws_cloudwatch_log_group.snow.name == "/aws/lambda/SNOW_btsgsd"
    )
    error_message = "SNOW_btsgsd must retain the requested function settings and omit reserved concurrency by default."
  }

  assert {
    condition = (
      jsondecode(aws_cloudformation_stack.snow.template_body).Resources.SNOWFunction.Type == "AWS::Lambda::Function" &&
      jsondecode(aws_cloudformation_stack.snow.template_body).Resources[local.version_logical_id].Type == "AWS::Lambda::Version" &&
      jsondecode(aws_cloudformation_stack.snow.template_body).Resources[local.version_logical_id].Properties.CodeSha256.Ref == "CodeHash" &&
      jsondecode(aws_cloudformation_stack.snow.template_body).Outputs.VersionArn.Value.Ref == local.version_logical_id
    )
    error_message = "Publish a version with the exact packaged-code hash and expose its ARN for SnapStart invocation."
  }

  assert {
    condition = (
      aws_s3_object.code.server_side_encryption == "AES256" &&
      aws_s3_bucket_public_access_block.code.block_public_acls &&
      aws_s3_bucket_public_access_block.code.block_public_policy &&
      aws_s3_bucket_public_access_block.code.ignore_public_acls &&
      aws_s3_bucket_public_access_block.code.restrict_public_buckets
    )
    error_message = "Lambda deployment packages must be encrypted and stored privately."
  }
}

run "optional_reserved_concurrency" {
  command = plan
  variables {
    reserved_concurrent_executions = 10
  }
  assert {
    condition     = jsondecode(aws_cloudformation_stack.snow.template_body).Resources.SNOWFunction.Properties.ReservedConcurrentExecutions == 10
    error_message = "An explicitly configured positive reservation must be passed to CloudFormation."
  }
}

run "zero_reservation_is_rejected" {
  command = plan
  variables {
    reserved_concurrent_executions = 0
  }
  expect_failures = [var.reserved_concurrent_executions]
}

run "negative_reservation_is_rejected" {
  command = plan
  variables {
    reserved_concurrent_executions = -1
  }
  expect_failures = [var.reserved_concurrent_executions]
}

run "fractional_reservation_is_rejected" {
  command = plan
  variables {
    reserved_concurrent_executions = 1.5
  }
  expect_failures = [var.reserved_concurrent_executions]
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
    error_message = "Pass ServiceNow instance and secret-name configuration to the supplied handler."
  }
}
