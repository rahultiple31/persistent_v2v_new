terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.100"
    }
  }
}

locals {
  partition   = split(":", var.lambda_arn)[1]
  region      = split(":", var.lambda_arn)[3]
  account_id  = split(":", var.lambda_arn)[4]
  connect_url = trimsuffix(var.connect_url, "/")

  gateway_source_arn = (
    var.gateway_id_audience == null
    ? "arn:${local.partition}:bedrock-agentcore:${local.region}:${local.account_id}:gateway/${var.gateway_name}-*"
    : "arn:${local.partition}:bedrock-agentcore:${local.region}:${local.account_id}:gateway/${var.gateway_id_audience}"
  )

  userlookup_schema = jsondecode(<<-JSON
[
  {
    "name": "UserLookUp___UserLookUp",
    "description": "UPI-only bot verification. Flow owns phone; NEVER send phone. After NotMatched/Error/blank/unknown, clear Yes to availability, full readback and separate confirmation. Max three confirmed submissions. No lookup on capture turn or name mismatch. Spoken bridge first. Current record match requires first-name check. UserNotRegistered normal no-match. (UPI-only release)",
    "inputSchema": {
      "type": "object",
      "properties": {
        "upi": {
          "type": "string",
          "description": "Caller's complete AbbVie Unique ID, collected one character at a time, read back and confirmed by the caller, then matched against sys_user.employee_number. Pass ALONE (never with phone), only after a phone no-match and a clear Yes to the UPI availability question. Send exactly the characters read back: same count, same order, nothing added or dropped. Never send a partial or empty ID."
        }
      },
      "required": [
        "upi"
      ]
    }
  }
]
JSON
  )

  gateway_template = {
    AWSTemplateFormatVersion = "2010-09-09"
    Description              = "AgentCore ${var.gateway_name} MCP gateway for ServiceNow user lookup."

    Parameters = {
      GatewayAudience = {
        Type    = "String"
        Default = ""
      }
    }

    Conditions = {
      HasGatewayAudience = {
        "Fn::Not" = [
          { "Fn::Equals" = [{ Ref = "GatewayAudience" }, ""] }
        ]
      }
    }

    Resources = merge({
      GatewayRole = {
        Type = "AWS::IAM::Role"

        Properties = {
          RoleName = var.role_name

          AssumeRolePolicyDocument = {
            Version = "2012-10-17"
            Statement = [{
              Effect    = "Allow"
              Principal = { Service = "bedrock-agentcore.amazonaws.com" }
              Action    = "sts:AssumeRole"

              Condition = {
                StringEquals = {
                  "aws:SourceAccount" = local.account_id
                }
                ArnLike = {
                  "aws:SourceArn" = local.gateway_source_arn
                }
              }
            }]
          }

          Policies = concat([{
            PolicyName = "InvokeServiceNowUserLookup"
            PolicyDocument = {
              Version = "2012-10-17"
              Statement = [{
                Effect   = "Allow"
                Action   = "lambda:InvokeFunction"
                Resource = var.lambda_arn
              }]
            }
            }], var.interaction_lambda_arn == null ? [] : [{
            PolicyName = "InvokeServiceNowInteraction"
            PolicyDocument = {
              Version = "2012-10-17"
              Statement = [{
                Effect   = "Allow"
                Action   = "lambda:InvokeFunction"
                Resource = var.interaction_lambda_arn
              }]
            }
          }])

          Tags = [
            for key, value in var.common_tags : {
              Key   = key
              Value = value
            }
          ]
        }
      }

      Gateway = {
        Type = "AWS::BedrockAgentCore::Gateway"

        Properties = {
          Name           = var.gateway_name
          Description    = "ServiceNow user lookup for the AbbVie Dev Connect instance."
          ProtocolType   = "MCP"
          AuthorizerType = "CUSTOM_JWT"
          RoleArn        = { "Fn::GetAtt" = ["GatewayRole", "Arn"] }

          AuthorizerConfiguration = {
            CustomJWTAuthorizer = {
              DiscoveryUrl = "${local.connect_url}/.well-known/openid-configuration"

              AllowedAudience = {
                "Fn::If" = [
                  "HasGatewayAudience",
                  [
                    local.connect_url,
                    { Ref = "GatewayAudience" }
                  ],
                  [local.connect_url]
                ]
              }
            }
          }

          Tags = var.common_tags

          # VPC security: none; no private endpoint configuration.
        }
      }

      UserLookupTarget = {
        Type = "AWS::BedrockAgentCore::GatewayTarget"

        Properties = {
          Name              = "snow-userlookup"
          Description       = "ServiceNow UserLookUp Lambda MCP target."
          GatewayIdentifier = { Ref = "Gateway" }

          CredentialProviderConfigurations = [{
            CredentialProviderType = "GATEWAY_IAM_ROLE"
          }]

          TargetConfiguration = {
            Mcp = {
              Lambda = {
                LambdaArn = var.lambda_arn

                ToolSchema = {
                  # Convert the supplied schema to CloudFormation property casing.
                  InlinePayload = [
                    for tool in local.userlookup_schema : {
                      Name        = tool.name
                      Description = tool.description

                      InputSchema = {
                        Type = tool.inputSchema.type
                        Properties = {
                          for name, property in tool.inputSchema.properties :
                          name => {
                            Type        = property.type
                            Description = property.description
                          }
                        }
                        Required = tool.inputSchema.required
                      }
                    }
                  ]
                }
              }
            }
          }
        }
      }
      }, var.interaction_lambda_arn == null ? {} : {
      InteractionTarget = local.interaction_target
    })

    Outputs = merge({
      GatewayId = {
        Value = { Ref = "Gateway" }
      }
      GatewayArn = {
        Value = { "Fn::GetAtt" = ["Gateway", "GatewayArn"] }
      }
      GatewayUrl = {
        Value = { "Fn::GetAtt" = ["Gateway", "GatewayUrl"] }
      }
      TargetId = {
        Value = { "Fn::GetAtt" = ["UserLookupTarget", "TargetId"] }
      }
      }, var.interaction_lambda_arn == null ? {} : {
      InteractionTargetId = {
        Value = { "Fn::GetAtt" = ["InteractionTarget", "TargetId"] }
      }
    })
  }
}

resource "aws_cloudformation_stack" "gateway" {
  name          = var.stack_name
  capabilities  = ["CAPABILITY_NAMED_IAM"]
  template_body = jsonencode(local.gateway_template)

  parameters = {
    GatewayAudience = var.gateway_id_audience == null ? "" : var.gateway_id_audience
  }

  tags = var.common_tags
}

locals {
  # Apply this target after the Interaction Lambda exists.
  # The current handler generates a CTI ScreenPopURL and ignores shortDescription.
  interaction_schema = jsondecode(<<-JSON
[
  {
    "name": "Interaction__Interaction",
    "description": "Create Interaction only before permitted Service Desk transfer with verified identity, nonempty returned UPI and trusted ContactId. Phone path uses returned UPI, no phone input. Skip for unverified/missing prerequisites, HR/FieldForce, Complete and confirmed Teams handoff. Skipped/failed Interaction never blocks permitted transfer; ScreenPopURL empty. Never submit empty UPI or retry unchanged MissingRequiredField. No Interaction for question-retry exhaustion; use Complete. No-input retry counter is separate from verification.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "contactId": {
          "type": "string",
          "description": "Amazon Connect ContactId. Used as the ServiceNow Correlation ID (sysparm_correlation_id)."
        },
        "description": {
          "type": "string",
          "description": "Detailed description (CallSummary) for the ServiceNow Interaction."
        },
        "shortDescription": {
          "type": "string",
          "description": "Short description for the ServiceNow Interaction."
        },
        "upi": {
          "type": "string",
          "description": "Nonempty UPI returned by verified phone match OR UPI match plus name check. Missing/unverified -> skip Interaction, not blank input."
        }
      },
      "required": [
        "upi",
        "contactId"
      ]
    }
  }
]
JSON
  )

  interaction_target = {
    Type      = "AWS::BedrockAgentCore::GatewayTarget"
    DependsOn = ["GatewayRole"]

    Properties = {
      Name              = "snow-interaction"
      Description       = "ServiceNow Interaction Lambda MCP target."
      GatewayIdentifier = { Ref = "Gateway" }

      CredentialProviderConfigurations = [{
        CredentialProviderType = "GATEWAY_IAM_ROLE"
      }]

      TargetConfiguration = {
        Mcp = {
          Lambda = {
            LambdaArn = var.interaction_lambda_arn

            ToolSchema = {
              InlinePayload = [
                for tool in local.interaction_schema : {
                  Name        = tool.name
                  Description = tool.description

                  InputSchema = {
                    Type = tool.inputSchema.type
                    Properties = {
                      for name, property in tool.inputSchema.properties :
                      name => {
                        Type        = property.type
                        Description = property.description
                      }
                    }
                    Required = tool.inputSchema.required
                  }
                }
              ]
            }
          }
        }
      }
    }
  }
}
