# Uses CloudFormation with the repository's existing AWS provider.
# https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-bedrockagentcore-gateway.html
# https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-bedrockagentcore-gatewaytarget.html
#
# Two applies are required:
# 1. Create the gateway using the Connect URL audience.
# 2. Save the generated Gateway ID in terraform.tfvars and apply again
#    to configure both requested audiences. Retain that setting for future runs.

variable "agentcore_gateway_id_audience" {
  description = "Generated Gateway ID used as the second allowed JWT audience; existing IDs remain valid after a gateway rename."
  type        = string
  default     = null

  validation {
    condition = var.agentcore_gateway_id_audience == null ? true : can(
      regex("^([0-9a-z][-]?){1,100}-[a-z0-9]{10}$", var.agentcore_gateway_id_audience)
    )
    error_message = "Use the actual Gateway ID returned by agentcore_gateway.id."
  }
}

locals {
  agentcore_gateway_name        = "gateway-quick-start-dev"
  agentcore_gateway_lambda_arn  = "arn:aws:lambda:us-east-1:518902362956:function:SNOW_btsgsd-dev"
  agentcore_gateway_connect_url = "https://btsgsd-dev-us-east-1.my.connect.aws"

  agentcore_userlookup_schema = jsondecode(<<-JSON
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

  agentcore_gateway_template = {
    AWSTemplateFormatVersion = "2010-09-09"
    Description              = "AgentCore gateway-quick-start-dev MCP gateway for ServiceNow user lookup."

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
          RoleName = "btsgsd-dev-agentcore-default-gateway-role"

          AssumeRolePolicyDocument = {
            Version = "2012-10-17"
            Statement = [{
              Effect    = "Allow"
              Principal = { Service = "bedrock-agentcore.amazonaws.com" }
              Action    = "sts:AssumeRole"

              Condition = {
                StringEquals = {
                  "aws:SourceAccount" = "518902362956"
                }
                ArnLike = {
                  "aws:SourceArn" = var.agentcore_gateway_id_audience == null ? "arn:aws:bedrock-agentcore:us-east-1:518902362956:gateway/${local.agentcore_gateway_name}-*" : "arn:aws:bedrock-agentcore:us-east-1:518902362956:gateway/${var.agentcore_gateway_id_audience}"
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
                Resource = local.agentcore_gateway_lambda_arn
              }]
            }
          }]

          Tags = [
            for key, value in local.common_tags : {
              Key   = key
              Value = value
            }
          ]
        }
      }

      Gateway = {
        Type = "AWS::BedrockAgentCore::Gateway"

        Properties = {
          Name           = local.agentcore_gateway_name
          Description    = "ServiceNow user lookup for the AbbVie Dev Connect instance."
          ProtocolType   = "MCP"
          AuthorizerType = "CUSTOM_JWT"
          RoleArn        = { "Fn::GetAtt" = ["GatewayRole", "Arn"] }

          AuthorizerConfiguration = {
            CustomJWTAuthorizer = {
              DiscoveryUrl = "${local.agentcore_gateway_connect_url}/.well-known/openid-configuration"

              AllowedAudience = {
                "Fn::If" = [
                  "HasGatewayAudience",
                  [
                    local.agentcore_gateway_connect_url,
                    { Ref = "GatewayAudience" }
                  ],
                  [local.agentcore_gateway_connect_url]
                ]
              }
            }
          }

          Tags = local.common_tags

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
                LambdaArn = local.agentcore_gateway_lambda_arn

                ToolSchema = {
                  # Convert the supplied schema to CloudFormation property casing.
                  InlinePayload = [
                    for tool in local.agentcore_userlookup_schema : {
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

resource "aws_cloudformation_stack" "agentcore_gateway" {
  count    = local.deploy_connect ? 1 : 0
  provider = aws.us_east_1

  name          = "btsgsd-dev-AgentCore-DefaultGateway"
  capabilities  = ["CAPABILITY_NAMED_IAM"]
  template_body = jsonencode(local.agentcore_gateway_template)

  parameters = {
    GatewayAudience = var.agentcore_gateway_id_audience == null ? "" : var.agentcore_gateway_id_audience
  }

  tags = local.common_tags
}

output "agentcore_gateway" {
  description = "gateway-quick-start-dev AgentCore gateway identifiers and MCP endpoint."

  value = try({
    name      = local.agentcore_gateway_name
    id        = aws_cloudformation_stack.agentcore_gateway[0].outputs["GatewayId"]
    arn       = aws_cloudformation_stack.agentcore_gateway[0].outputs["GatewayArn"]
    url       = aws_cloudformation_stack.agentcore_gateway[0].outputs["GatewayUrl"]
    target_id = aws_cloudformation_stack.agentcore_gateway[0].outputs["TargetId"]
    tool_name = "snow-userlookup___UserLookUp"
  }, null)
}

# Deployment sequence: use the existing Dev Connect backend and AWS credentials.
#
# terraform -chdir=environments/dev plan \
#   -var='enabled_modules=["connect"]' \
#   -target=aws_cloudformation_stack.agentcore_gateway \
#   -out=agentcore-bootstrap.tfplan
#
# terraform -chdir=environments/dev apply agentcore-bootstrap.tfplan
# terraform -chdir=environments/dev output -json agentcore_gateway
#
# Add the returned ID to environments/dev/terraform.tfvars:
# agentcore_gateway_id_audience = "gateway-quick-start-dev-<actual-generated-suffix>"
# For a previously created gateway, use its returned ID even if it starts with default-.
#
# Retain that setting for future pipeline runs, then configure both audiences:
#
# terraform -chdir=environments/dev plan \
#   -var='enabled_modules=["connect"]' \
#   -target=aws_cloudformation_stack.agentcore_gateway \
#   -out=agentcore-final.tfplan
#
# terraform -chdir=environments/dev apply agentcore-final.tfplan
