mock_provider "aws" {}

mock_provider "aws" {
  alias = "us_east_1"

  mock_resource "aws_cloudformation_stack" {
    defaults = {
      outputs = {
        DataTableArn = "arn:aws:connect:us-east-1:518902362956:instance/bcc989e5-cd9d-494f-9cd4-434f39ccc90e/data-table/00000000-0000-0000-0000-000000000001"
      }
    }
  }

  mock_data "aws_connect_instance" {
    defaults = {
      id  = "bcc989e5-cd9d-494f-9cd4-434f39ccc90e"
      arn = "arn:aws:connect:us-east-1:518902362956:instance/bcc989e5-cd9d-494f-9cd4-434f39ccc90e"
    }
  }
}

mock_provider "awscc" {
  alias = "us_east_1"
}
mock_provider "archive" {}
mock_provider "external" {}

# Deliberately omit VMX3 dependencies: a table choice uses the existing instance.
variables {
  environment             = "v2v"
  enabled_modules         = ["connect"]
  translation_enabled     = false
  cognito_domain_prefix   = "table-choice-test"
  connect_instance_url    = "https://btsgsd-dev-v2v-poc-us-east-1.my.connect.aws"
  connect_instance_region = "us-east-1"
  connect_instance_alias  = "btsgsd-dev-v2v-poc-us-east-1"
}

run "customer_number" {
  # Resolve targeted child-module outputs through the mocked provider.
  command = apply
  plan_options {
    target = [module.bts_gsd_customer_number_data_table[0]]
  }
  assert {
    condition = (
      output.bts_gsd_customer_number_data_table.name == "BTSGSD-V2V-US-BTSGSD-CustomerNumber" &&
      startswith(output.bts_gsd_customer_number_data_table.arn, "${data.aws_connect_instance.target[0].arn}/data-table/") &&
      output.bts_gsd_customer_number_data_table.id == "00000000-0000-0000-0000-000000000001"
    )
    error_message = "Retain the existing table name, ARN, and ID output contract after module extraction."
  }
}

run "hr_transfer" {
  command = plan
  plan_options {
    target = [aws_cloudformation_stack.hr_transfer_data_table[0]]
  }
  assert {
    condition = (
      aws_cloudformation_stack.hr_transfer_data_table[0].parameters.InstanceArn == data.aws_connect_instance.target[0].arn &&
      jsondecode(aws_cloudformation_stack.hr_transfer_data_table[0].template_body).Resources.HRTransferTable.Properties.Name == "BTSGSD-V2V-US-BTSGSD-HR_Transfer"
    )
    error_message = "The HR-transfer choice must use its own table and the existing V2V instance."
  }
}

run "survey" {
  # Mock apply resolves the bucket endpoint used by the stack template URL.
  command = apply

  variables {
    dev_ai_template_bucket = "test-v2v-prompt-template-bucket"
  }

  override_resource {
    target = aws_s3_bucket.dev_ai_template[0]
    values = {
      id                          = "test-v2v-prompt-template-bucket"
      bucket_regional_domain_name = "test-v2v-prompt-template-bucket.s3.us-east-1.amazonaws.com"
    }
  }

  plan_options {
    target = [module.survey_data_table[0]]
  }
  assert {
    condition = (
      output.survey_data_table.name == "BTSGSD-V2V-US-PROMPT-DATATABLE" &&
      startswith(output.survey_data_table.arn, "${data.aws_connect_instance.target[0].arn}/data-table/") &&
      output.survey_data_table.id == "00000000-0000-0000-0000-000000000001"
    )
    error_message = "Retain the existing table name, ARN, and ID output contract after module extraction."
  }
}

run "veeva_transfer" {
  command = plan
  plan_options {
    target = [aws_cloudformation_stack.veeva_transfer_data_table[0]]
  }
  assert {
    condition = (
      aws_cloudformation_stack.veeva_transfer_data_table[0].parameters.InstanceArn == data.aws_connect_instance.target[0].arn &&
      jsondecode(aws_cloudformation_stack.veeva_transfer_data_table[0].template_body).Resources.VeevaTransferTable.Properties.Name == "BTSGSD-V2V-US-BTSGSD-Veeva_Transfer"
    )
    error_message = "The Veeva-transfer choice must use its own table and the existing V2V instance."
  }
}

run "top_level_blocker" {
  command = plan
  plan_options {
    target = [aws_cloudformation_stack.top_level_blocker_data_table[0]]
  }
  assert {
    condition = (
      aws_cloudformation_stack.top_level_blocker_data_table[0].parameters.InstanceArn == data.aws_connect_instance.target[0].arn &&
      jsondecode(aws_cloudformation_stack.top_level_blocker_data_table[0].template_body).Resources.TopLevelBlockerTable.Properties.Name == "BTSGSD-V2V-US-TopLevelBlockerMessage"
    )
    error_message = "The blocker-message choice must use its own table and the existing V2V instance."
  }
}
