terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.100.0, < 7.0.0"
    }
  }
}

resource "aws_cloudformation_stack" "integration" {
  name = var.stack_name
  tags = var.common_tags

  template_body = jsonencode({
    AWSTemplateFormatVersion = "2010-09-09"
    Description              = "Amazon Connect MCP server integration."

    Resources = {
      McpApplication = {
        Type = "AWS::AppIntegrations::Application"

        Properties = {
          Name            = var.display_name
          Namespace       = var.gateway_id
          ApplicationType = "MCP_SERVER"
          Description     = "AgentCore MCP server integration for Amazon Connect."

          ApplicationSourceConfig = {
            ExternalUrlConfig = {
              AccessUrl = var.gateway_url
            }
          }

          Tags = [
            for key, value in var.common_tags : {
              Key   = key
              Value = value
            }
          ]
        }
      }

      ConnectAssociation = {
        Type = "AWS::Connect::IntegrationAssociation"

        Properties = {
          # CloudFormation requires the full Connect instance ARN.
          InstanceId      = var.connect_instance_arn
          IntegrationType = "APPLICATION"
          IntegrationArn  = { "Fn::GetAtt" = ["McpApplication", "ApplicationArn"] }
        }
      }
    }

    Outputs = {
      ApplicationId = {
        Value = { "Fn::GetAtt" = ["McpApplication", "Id"] }
      }

      ApplicationArn = {
        Value = { "Fn::GetAtt" = ["McpApplication", "ApplicationArn"] }
      }

      AssociationId = {
        Value = { "Fn::GetAtt" = ["ConnectAssociation", "IntegrationAssociationId"] }
      }
    }
  })
}
