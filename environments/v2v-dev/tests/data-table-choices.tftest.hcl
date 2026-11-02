mock_provider "aws" {}

mock_provider "aws" {
  alias = "us_east_1"

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
  command = plan
  plan_options {
    target = [aws_cloudformation_stack.bts_gsd_customer_number_data_table[0]]
  }
  assert {
    condition = (
      aws_cloudformation_stack.bts_gsd_customer_number_data_table[0].parameters.InstanceArn == data.aws_connect_instance.target[0].arn &&
      jsondecode(aws_cloudformation_stack.bts_gsd_customer_number_data_table[0].template_body).Resources.CustomerNumberTable.Properties.Name == "BTSGSD-V2V-US-BTSGSD-CustomerNumber"
    )
    error_message = "The customer-number choice must use its own table and the existing V2V instance."
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
  command = plan
  plan_options {
    target = [aws_cloudformation_stack.survey_data_table[0]]
  }
  assert {
    condition = (
      aws_cloudformation_stack.survey_data_table[0].parameters.InstanceArn == data.aws_connect_instance.target[0].arn &&
      jsondecode(aws_cloudformation_stack.survey_data_table[0].template_body).Resources.SurveyTable.Properties.Name == "BTSGSD-V2V-US-PROMPT-DATATABLE"
    )
    error_message = "The survey choice must use its own table and the existing V2V instance."
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
