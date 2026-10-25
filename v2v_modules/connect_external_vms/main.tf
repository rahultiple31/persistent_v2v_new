data "aws_connect_instance" "this" {
  instance_alias = var.instance_name
}

resource "aws_connect_quick_connect" "external_vms" {
  instance_id = data.aws_connect_instance.this.id

  name        = var.external_vm_name
  description = "External voicemail transfer"

  quick_connect_config {
    quick_connect_type = "PHONE_NUMBER"

    phone_config {
      phone_number = var.external_vm_phone_number
    }
  }

  tags = {
    Environment = "v2v"
    ManagedBy   = "Terraform"
  }
}