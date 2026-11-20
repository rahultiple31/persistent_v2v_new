mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { region = "us-east-1" }
  }
}
mock_provider "external" {
  mock_data "external" {
    defaults = { result = { content = "{\"StartAction\":\"resolved\",\"Actions\":[{\"Type\":\"DisconnectParticipant\"}]}" } }
  }
}

variables {
  settings = {
    instance_arn             = "arn:aws:connect:us-east-1:518902362956:instance/bcc989e5-cd9d-494f-9cd4-434f39ccc90e"
    queue_metrics_lambda_arn = "arn:aws:lambda:us-east-1:518902362956:function:BTSGSD-V2V-US-conversionOfQueueMetrics"
    survey_data_table_id     = "79f7f226-c0a3-45e2-bb9c-d0e7bb500733"
  }
}

run "source_instance_and_lex_bots_are_forbidden_after_resolution" {
  command = plan
  assert {
    # The dev instance and the BTSGSD-SSO-US customer-queue and yes/no bots in the export.
    condition = toset(local.source_references) == toset([
      "c227a737-3e4f-4c64-8397-2d37e318801d",
      "RD35A35EAU",
      "QT2GQYM5TT",
    ])
    error_message = "Every Connect instance and Lex bot of the export must be checked for in the deployed flow."
  }
  assert {
    condition = (
      strcontains(module.flow.flow_name, "BTSGSD-V2V-US-CustomerQueueFlow") &&
      !strcontains(local.export, "BTSGSD-V2V-US-conversionOfQueueMetrics")
    )
    error_message = "The export stays unchanged in the repository; replacements happen at plan time."
  }
}

# A source ID left after resolution fails the plan; that check lives in
# connect_flow_resource (tests/resource.tftest.hcl), which this module calls.
