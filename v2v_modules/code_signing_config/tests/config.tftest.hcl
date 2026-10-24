mock_provider "aws" {}

variables {
  signing_profile_version_arn = "arn:aws:signer:us-east-1:518902362956:/signing-profiles/BTFSD_V2V_US/1234567890"
}

run "trusts_the_exact_profile_version_without_enforcing_unsigned_packages" {
  command = plan

  variables {
    common_tags = {
      Environment = "v2v"
    }
  }

  assert {
    condition = (
      aws_lambda_code_signing_config.this.allowed_publishers[0].signing_profile_version_arns == toset([var.signing_profile_version_arn]) &&
      aws_lambda_code_signing_config.this.policies[0].untrusted_artifact_on_deployment == "Warn" &&
      aws_lambda_code_signing_config.this.tags.Environment == "v2v"
    )
    error_message = "Trust the requested profile version, keep Warn behavior, and propagate tags."
  }
}

run "unversioned_profile_arn_is_rejected" {
  command = plan

  variables {
    signing_profile_version_arn = "arn:aws:signer:us-east-1:518902362956:/signing-profiles/BTFSD_V2V_US"
  }

  expect_failures = [var.signing_profile_version_arn]
}

run "unrelated_arn_is_rejected" {
  command = plan

  variables {
    signing_profile_version_arn = "arn:aws:lambda:us-east-1:518902362956:function:example"
  }

  expect_failures = [var.signing_profile_version_arn]
}
