mock_provider "aws" {}

run "name_only_leaves_optional_properties_unset" {
  command = plan

  variables {
    log_group_name = "/aws/lex/example"
  }

  assert {
    condition = (
      aws_cloudwatch_log_group.this.name == "/aws/lex/example" &&
      aws_cloudwatch_log_group.this.retention_in_days == null &&
      aws_cloudwatch_log_group.this.kms_key_id == null &&
      aws_cloudwatch_log_group.this.tags == null
    )
    error_message = "Callers that pass only a name must get a log group with no retention, KMS key or tags set."
  }
}

run "retention_class_kms_and_tags_are_applied" {
  command = plan

  variables {
    log_group_name    = "/aws/lex/example"
    retention_in_days = 30
    log_group_class   = "STANDARD"
    kms_key_id        = "arn:aws:kms:us-east-1:111111111111:key/22222222-2222-2222-2222-222222222222"
    tags              = { Project = "example" }
  }

  assert {
    condition = (
      aws_cloudwatch_log_group.this.retention_in_days == 30 &&
      aws_cloudwatch_log_group.this.log_group_class == "STANDARD" &&
      aws_cloudwatch_log_group.this.kms_key_id == "arn:aws:kms:us-east-1:111111111111:key/22222222-2222-2222-2222-222222222222" &&
      aws_cloudwatch_log_group.this.tags["Project"] == "example"
    )
    error_message = "Retention, class, KMS key and tags must reach the log group."
  }
}

run "reject_unknown_log_group_class" {
  command = plan

  variables {
    log_group_name  = "/aws/lex/example"
    log_group_class = "ARCHIVE"
  }

  expect_failures = [var.log_group_class]
}
