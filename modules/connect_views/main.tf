terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.100.0, < 7.0.0"
    }
  }
}

# Connect generates the input schema from Template. InputSchema is not a
# writable property of AWS::Connect::View.
resource "aws_cloudformation_stack" "this" {
  name = var.stack_name
  tags = var.common_tags

  template_body = jsonencode({
    AWSTemplateFormatVersion = "2010-09-09"
    Description              = "Customer Details view for the Amazon Connect agent workspace."

    Resources = {
      CustomerDetails = {
        Type = "AWS::Connect::View"

        Properties = {
          InstanceArn = var.connect_instance_arn
          Name        = var.view_name
          Description = "Caller identity, verification, call summary and ServiceNow screen pop."
          Actions     = ["Close"]
          Template    = jsondecode(var.view_template)

          Tags = [
            for key, value in var.common_tags : {
              Key   = key
              Value = value
            }
          ]
        }
      }
    }

    Outputs = {
      ViewArn = {
        Value = { "Fn::GetAtt" = ["CustomerDetails", "ViewArn"] }
      }
      ViewId = {
        Value = { "Fn::GetAtt" = ["CustomerDetails", "ViewId"] }
      }
    }
  })
}
