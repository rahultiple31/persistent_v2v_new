mock_provider "aws" {
  mock_data "aws_connect_instance" {
    defaults = {
      id  = "bcc989e5-cd9d-494f-9cd4-434f39ccc90e"
      arn = "arn:aws:connect:us-east-1:518902362956:instance/bcc989e5-cd9d-494f-9cd4-434f39ccc90e"
    }
  }
}

variables {
  instance_name            = "btsgsd-dev-v2v-poc-us-east-1"
  external_vm_phone_number = "+18557117965"
}

run "creates_phone_quick_connect_in_selected_instance" {
  command = plan

  assert {
    condition = (
      aws_connect_quick_connect.external_vms.instance_id == "bcc989e5-cd9d-494f-9cd4-434f39ccc90e" &&
      aws_connect_quick_connect.external_vms.name == "External VMs" &&
      aws_connect_quick_connect.external_vms.quick_connect_config[0].quick_connect_type == "PHONE_NUMBER" &&
      aws_connect_quick_connect.external_vms.quick_connect_config[0].phone_config[0].phone_number == "+18557117965"
    )
    error_message = "Create the External VMs phone quick connect in the selected Connect instance."
  }
}

run "rejects_placeholder_phone_number" {
  command = plan

  variables {
    external_vm_phone_number = "+1XXXXXXXXXX"
  }

  expect_failures = [var.external_vm_phone_number]
}

run "rejects_phone_number_uuid_as_destination" {
  command = plan

  variables {
    external_vm_phone_number = "74710dfe-bd4a-468a-946a-f36a48523bc9"
  }

  expect_failures = [var.external_vm_phone_number]
}
