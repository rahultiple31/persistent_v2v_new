mock_provider "aws" {}

run "lambda_profile_keeps_existing_identity" {
  command = plan

  variables {
    common_tags = {
      Project = "v2v-signing"
    }
  }

  assert {
    condition = (
      aws_signer_signing_profile.this[0].name == "BTFSD_V2V_US" &&
      aws_signer_signing_profile.this[0].platform_id == "AWSLambda-SHA384-ECDSA" &&
      aws_signer_signing_profile.this[0].tags.Project == "v2v-signing" &&
      aws_signer_signing_profile.this[0].tags.Environment == "v2v"
    )
    error_message = "Keep the existing Lambda signing identity and propagate deployment tags."
  }
}

run "disabled_profile_has_no_resources_or_outputs" {
  command = plan

  variables {
    create_signing_profile = false
  }

  assert {
    condition = (
      length(aws_signer_signing_profile.this) == 0 &&
      output.signing_profile_name == null &&
      output.signing_profile_arn == null &&
      output.signing_profile_version_arn == null
    )
    error_message = "Disabling profile creation must safely return null outputs."
  }
}

run "invalid_profile_name_is_rejected" {
  command = plan

  variables {
    profile_name = "invalid-profile-name"
  }

  expect_failures = [var.profile_name]
}
