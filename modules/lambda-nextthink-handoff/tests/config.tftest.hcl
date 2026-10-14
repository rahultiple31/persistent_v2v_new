mock_provider "aws" {
  mock_data "aws_secretsmanager_secret" {
    defaults = {
      arn = "arn:aws:secretsmanager:us-east-1:518902362956:secret:Nextthink/Clientid/Secretkey-abcdef"
    }
  }

  mock_data "aws_region" {
    defaults = { name = "us-east-1" }
  }

  mock_resource "aws_cloudformation_stack" {
    defaults = {
      outputs = {
        FunctionName = "Nextthink_Handoff_btsgsd-dev"
        FunctionArn  = "arn:aws:lambda:us-east-1:518902362956:function:Nextthink_Handoff_btsgsd-dev"
      }
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

run "requested_lambda_configuration" {
  command = plan

  assert {
    condition = (
      jsondecode(aws_cloudformation_stack.handoff.template_body).Resources.HandoffFunction.Properties.FunctionName == "Nextthink_Handoff_btsgsd-dev" &&
      jsondecode(aws_cloudformation_stack.handoff.template_body).Resources.HandoffFunction.Properties.Runtime == "python3.14" &&
      jsondecode(aws_cloudformation_stack.handoff.template_body).Resources.HandoffFunction.Properties.Architectures == ["x86_64"] &&
      jsondecode(aws_cloudformation_stack.handoff.template_body).Resources.HandoffFunction.Properties.Handler == "lambda_function.lambda_handler" &&
      jsondecode(aws_cloudformation_stack.handoff.template_body).Resources.HandoffFunction.Properties.MemorySize == 128 &&
      jsondecode(aws_cloudformation_stack.handoff.template_body).Resources.HandoffFunction.Properties.Timeout == 8 &&
      jsondecode(aws_cloudformation_stack.handoff.template_body).Resources.HandoffFunction.Properties.ReservedConcurrentExecutions == 200 &&
      jsondecode(aws_cloudformation_stack.handoff.template_body).Resources.HandoffFunction.Properties.Environment.Variables.NEXTHINK_SECRET_NAME == "Nextthink/Clientid/Secretkey" &&
      aws_cloudformation_stack.handoff.parameters.LogGroupName == "/aws/lambda/Nextthink_Handoff" &&
      jsondecode(aws_cloudformation_stack.handoff.template_body).Resources.HandoffFunction.Properties.LoggingConfig.LogGroup.Ref == "LogGroupName" &&
      jsondecode(aws_cloudformation_stack.handoff.template_body).Resources.HandoffFunction.Properties.Code.S3Key.Ref == "CodeKey" &&
      data.archive_file.handoff.source_dir == "./src" &&
      aws_s3_object.code.source_hash == data.archive_file.handoff.output_base64sha256
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
    }
  }

  assert {
    condition = (
      length(jsondecode(aws_iam_role_policy.execution.policy).Statement) == 3 &&
      jsondecode(aws_iam_role_policy.execution.policy).Statement[2].Action == ["kms:Decrypt"] &&
      jsondecode(aws_iam_role_policy.execution.policy).Statement[2].Resource == var.secret_kms_key_arn &&
      jsondecode(aws_iam_role_policy.execution.policy).Statement[2].Condition.StringEquals["kms:ViaService"] == "secretsmanager.us-east-1.amazonaws.com" &&
      jsondecode(aws_iam_role_policy.execution.policy).Statement[2].Condition.StringEquals["kms:EncryptionContext:SecretARN"] == data.aws_secretsmanager_secret.credentials.arn &&
      jsondecode(aws_cloudformation_stack.handoff.template_body).Resources.HandoffFunction.Properties.Environment.Variables.NEXTHINK_SECRET_NAME == "Nextthink/Clientid/Secretkey" &&
      jsondecode(aws_cloudformation_stack.handoff.template_body).Resources.HandoffFunction.Properties.Environment.Variables.READ_TIMEOUT_SECONDS == "1"
    )
    error_message = "KMS decryption must be limited to the configured key and secret; preserve the required secret name when adding overrides."
  }
}

run "insufficient_concurrency_is_rejected" {
  command = plan

  override_data {
    target = data.external.capacity
    values = {
      result = {
        unreserved          = "299"
        current_reservation = "0"
        maximum_reservation = "199"
      }
    }
  }

  expect_failures = [aws_cloudformation_stack.handoff]
}
