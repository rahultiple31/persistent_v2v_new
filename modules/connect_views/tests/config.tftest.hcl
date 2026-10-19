mock_provider "awscc" {
  mock_resource "awscc_connect_view" {
    defaults = {
      view_id  = "11111111-1111-1111-1111-111111111111"
      view_arn = "arn:aws:connect:us-east-1:123456789012:instance/22222222-2222-2222-2222-222222222222/view/11111111-1111-1111-1111-111111111111"
    }
  }
}

variables {
  connect_instance_arn = "arn:aws:connect:us-east-1:123456789012:instance/22222222-2222-2222-2222-222222222222"
  view_template        = file("../../environments/dev/metadata/views/customer_details.json")
  common_tags          = { Environment = "dev" }
}

run "json_layout_and_actions" {
  command = plan

  assert {
    condition = (
      awscc_connect_view.customer_details.name == "Customer Details" &&
      jsondecode(awscc_connect_view.customer_details.template).Head.Title == "Customer Details" &&
      awscc_connect_view.customer_details.template == var.view_template &&
      toset(awscc_connect_view.customer_details.actions) == toset(["Close"]) &&
      contains(awscc_connect_view.customer_details.tags, { key = "Environment", value = "dev" })
    )
    error_message = "The view must use the JSON layout, its Close action, and the supplied tags."
  }
}

run "version_qualified_arn" {
  command = apply

  assert {
    condition = (
      output.view_id == "11111111-1111-1111-1111-111111111111" &&
      output.view_latest_arn == "${output.view_arn}:$LATEST"
    )
    error_message = "The contact flow must receive the view ARN qualified with $LATEST."
  }
}

run "reject_input_schema_as_layout" {
  command = plan

  variables {
    view_template = jsonencode({ type = "object", properties = {} })
  }

  expect_failures = [var.view_template]
}
