locals {
  guardrail_resources = {
    for logical_id, resource in {
      SupportGuardrail = {
        Type = "AWS::Wisdom::AIGuardrail"

        Properties = {
          AssistantId = var.assistant_id
          Name        = var.guardrail_name
          Description = "Content filters only for AbbVie Service Desk IVA"

          BlockedInputMessaging   = "I can help with AbbVie Service Desk requests. Please rephrase your request."
          BlockedOutputsMessaging = "I cannot provide that response. Please rephrase your support request."

          ContentPolicyConfig = {
            FiltersConfig = [
              {
                Type           = "PROMPT_ATTACK"
                InputStrength  = "MEDIUM"
                OutputStrength = "NONE"
              }
            ]
          }

          Tags = local.tags
        }
      }

      SupportGuardrailVersion = {
        Type = "AWS::Wisdom::AIGuardrailVersion"

        Properties = {
          AssistantId = var.assistant_id

          AIGuardrailId = {
            "Fn::GetAtt" = ["SupportGuardrail", "AIGuardrailId"]
          }

          ModifiedTimeSeconds = {
            "Fn::GetAtt" = ["SupportGuardrail", "ModifiedTimeSeconds"]
          }
        }
      }
    } : logical_id => resource
    if var.guardrail_name != null
  }

  guardrail_configuration_override = {
    for key, value in {
      OrchestrationAIGuardrailId = {
        "Fn::GetAtt" = ["SupportGuardrailVersion", "AIGuardrailVersionId"]
      }
    } : key => value
    if var.guardrail_name != null
  }
}
