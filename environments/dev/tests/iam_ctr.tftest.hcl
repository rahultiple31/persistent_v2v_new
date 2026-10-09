mock_provider "aws" {}

mock_provider "aws" {
  alias = "us_east_1"
}

mock_provider "aws" {
  alias = "proxy_us_east_1"
}

mock_provider "external" {}

run "iam_ctr_target_is_isolated" {
  command = plan

  variables {
    enabled_modules = ["iam-ctr"]
  }

  assert {
    condition = (
      length(module.iam-ctr) == 1 &&
      length(module.lambda-ctr-survey) == 0 &&
      length(module.lambda-connect-daily-ctr-export) == 0 &&
      length(module.lambda-ctr-raw) == 0 &&
      length(module.connect_us_east_1) == 0 &&
      length(module.lambda_us_east_1) == 0 &&
      length(module.s3_connect_reporting) == 0
    )
    error_message = "The IAM CTR target must attach permissions without creating Lambda roles, functions, Connect instances, or reporting buckets."
  }
}

run "lambda_target_excludes_shared_iam_policy" {
  command = plan

  variables {
    enabled_modules = ["lambda-connect-daily-ctr-export"]
  }

  assert {
    condition     = length(module.iam-ctr) == 0
    error_message = "Lambda deployment states must not manage the shared IAM CTR policy."
  }
}

run "shared_policy_permissions_and_attachments" {
  command = plan

  module {
    source = "../../modules/iam-ctr"
  }

  variables {
    policy_name   = "btsgsd-dev-us-east-1-ctr-reporting-policy"
    s3_object_arn = "arn:aws:s3:::btsgsd-dev-us-east-1-connect-reporting-bucket/connect/daily-interactions/*"
    role_names = [
      "btsgsd-dev-us-east-1-CTR-Survey-lambda-role",
      "btsgsd-dev-us-east-1-connect-daily-ctr-export-lambda-role",
      "btsgsd-dev-us-east-1-CTR-Raw-lambda-role"
    ]
  }

  assert {
    condition = (
      length(aws_iam_role_policy_attachment.ctr) == 3 &&
      toset([for attachment in aws_iam_role_policy_attachment.ctr : attachment.role]) == var.role_names
    )
    error_message = "The shared policy must be attached to all three existing Lambda execution roles."
  }

  assert {
    condition = (
      jsondecode(aws_iam_policy.ctr.policy).Version == "2012-10-17" &&
      length(jsondecode(aws_iam_policy.ctr.policy).Statement) == 2 &&
      jsondecode(aws_iam_policy.ctr.policy).Statement[0].Effect == "Allow" &&
      jsondecode(aws_iam_policy.ctr.policy).Statement[0].Resource == "*" &&
      toset(jsondecode(aws_iam_policy.ctr.policy).Statement[0].Action) == toset([
        "connect:SearchContacts",
        "connect:DescribeContact",
        "connect:GetContactAttributes",
        "connect:DescribeUser",
        "connect:DescribeQueue"
      ]) &&
      jsondecode(aws_iam_policy.ctr.policy).Statement[1].Effect == "Allow" &&
      jsondecode(aws_iam_policy.ctr.policy).Statement[1].Resource == var.s3_object_arn &&
      toset(jsondecode(aws_iam_policy.ctr.policy).Statement[1].Action) == toset(["s3:PutObject", "s3:AbortMultipartUpload"])
    )
    error_message = "The shared policy must grant the requested Connect reads and restrict S3 writes to the daily-interactions prefix."
  }
}
