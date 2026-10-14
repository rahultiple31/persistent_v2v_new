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
    "name": "UserLookUp",
    "description": "Verify a caller's identity against the ServiceNow sys_user table for the AbbVie Service Desk IVA. The contact flow normally runs the phone lookup before the bot starts and passes PhoneLookupStatus (Matched/NotMatched/Error) plus the caller profile; when it is Matched or NotMatched, do NOT call this tool with phone. Call with 'phone' ALONE only when PhoneLookupStatus is Error, blank or unknown and caller_ani is nonempty, once per call, never repeated after a match or no-match. Call with 'upi' ALONE only after a phone no-match (flow NotMatched, or UserNotRegistered/MissingIdentifier) AND the caller gave a clear Yes to the UPI availability question AND confirmed the readback of the WHOLE ID; or when the caller explicitly corrects a UPI within the remaining budget. No intent classification is needed before a UPI call. Never call it for a No, unclear or non-yes/no answer to the UPI availability question, or after Manufacturing, M&A, HR or any issue is stated instead of yes/no. At most three UPI submissions per conversation; a first-name mismatch never triggers another UPI call. Always speak a short spoken message in the same response before calling. Never combine phone and upi, and never send an empty or partial value. The 'upi' value is matched against sys_user.employee_number. UserNotRegistered and a phone-path MissingIdentifier are normal no-match results, not failures. Returns Status (\"Authenticated\"/\"Unauthenticated\"), AuthResult (\"Success\" when sys_user returned the record, \"Failure\" when it did not), RegisteredCaller (\"Yes\"/\"No\"), and on success the caller's sys_user record, including FirstName, LastName, UPI, UserId, Email, FieldForce (\"true\"/\"false\"), Active, StartDate, UserStatus (\"pre-hired\"/\"new-hired\"/\"existing-user\") and Phone. On failure: Error and Message. Does NOT create or update any ServiceNow record.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "phone": {
          "type": "string",
          "description": "Caller's ANI/phone number, passed exactly as received from the caller_ani custom variable. Fallback only: use ALONE, once per call, only when the flow's PhoneLookupStatus is Error, blank or unknown. Never send when the flow already returned Matched or NotMatched, never empty, never combined with upi."
        },
        "upi": {
          "type": "string",
          "description": "Caller's complete AbbVie Unique ID, collected one character at a time, read back and confirmed by the caller, then matched against sys_user.employee_number. Pass ALONE (never with phone), only after a phone no-match and a clear Yes to the UPI availability question. Send exactly the characters read back: same count, same order, nothing added or dropped. Never send a partial or empty ID."
        }
      }
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

    Resources = {
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

          Policies = [{
            PolicyName = "InvokeServiceNowUserLookup"
            PolicyDocument = {
              Version = "2012-10-17"
              Statement = [{
                Effect   = "Allow"
                Action   = "lambda:InvokeFunction"
                Resource = var.lambda_arn
              }]
            }
          }]

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

    Outputs = {
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
    }
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
