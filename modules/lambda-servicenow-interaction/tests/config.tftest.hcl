mock_provider "aws" {}

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
      jsondecode(aws_cloudformation_stack.interaction.template_body).Resources.InteractionFunction.Properties.FunctionName == "ServiceNow_Interaction_btsgsd-dev" &&
      jsondecode(aws_cloudformation_stack.interaction.template_body).Resources.InteractionFunction.Properties.Runtime == "python3.14" &&
      jsondecode(aws_cloudformation_stack.interaction.template_body).Resources.InteractionFunction.Properties.Architectures == ["x86_64"] &&
      jsondecode(aws_cloudformation_stack.interaction.template_body).Resources.InteractionFunction.Properties.Handler == "lambda_function.lambda_handler" &&
      jsondecode(aws_cloudformation_stack.interaction.template_body).Resources.InteractionFunction.Properties.MemorySize == 512 &&
      jsondecode(aws_cloudformation_stack.interaction.template_body).Resources.InteractionFunction.Properties.Timeout == 8 &&
      jsondecode(aws_cloudformation_stack.interaction.template_body).Resources.InteractionFunction.Properties.EphemeralStorage.Size == 512 &&
      jsondecode(aws_cloudformation_stack.interaction.template_body).Resources.InteractionFunction.Properties.ReservedConcurrentExecutions == 100 &&
      aws_cloudformation_stack.interaction.parameters.LogGroupName == "/aws/lambda/ServiceNow_Interaction" &&
      jsondecode(aws_cloudformation_stack.interaction.template_body).Resources.InteractionFunction.Properties.LoggingConfig.LogGroup.Ref == "LogGroupName" &&
      data.archive_file.interaction.source_dir == "./src" &&
      aws_s3_object.code.source_hash == data.archive_file.interaction.output_base64sha256
    )
    error_message = "Deploy the requested runtime, architecture, handler, capacity and custom logging configuration using the source ZIP."
  }

  assert {
    condition = (
      jsondecode(aws_cloudformation_stack.interaction.template_body).Resources.InteractionFunction.Properties.Code.S3Bucket.Ref == "CodeBucket" &&
      jsondecode(aws_cloudformation_stack.interaction.template_body).Resources.InteractionFunction.Properties.Code.S3Key.Ref == "CodeKey" &&
      jsondecode(aws_cloudformation_stack.interaction.template_body).Resources.InteractionFunction.Properties.Environment.Variables.SN_INSTANCE == "abbvienowdev" &&
      jsondecode(aws_cloudformation_stack.interaction.template_body).Resources.InteractionFunction.Properties.Environment.Variables.SN_CTI_RULE == "cti_gsd" &&
      length(jsondecode(aws_cloudformation_stack.interaction.template_body).Resources) == 1
    )
    error_message = "Use the uploaded source and supplied handler defaults without adding versions or unrelated CloudFormation resources."
  }
}

run "environment_override_preserves_other_defaults" {
  command = plan

  variables {
    environment_variables = { SN_INSTANCE = "exampledev" }
  }

  assert {
    condition = (
      jsondecode(aws_cloudformation_stack.interaction.template_body).Resources.InteractionFunction.Properties.Environment.Variables.SN_INSTANCE == "exampledev" &&
      jsondecode(aws_cloudformation_stack.interaction.template_body).Resources.InteractionFunction.Properties.Environment.Variables.SN_CTI_RULE == "cti_gsd"
    )
    error_message = "An instance override must retain the CTI rule default."
  }
}

run "insufficient_concurrency_is_rejected" {
  command = plan

  override_data {
    target = data.external.capacity
    values = {
      result = {
        unreserved          = "199"
        current_reservation = "0"
        maximum_reservation = "99"
      }
    }
  }

  expect_failures = [aws_cloudformation_stack.interaction]
}
