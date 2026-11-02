# AWS CLI inherits the same OIDC credentials as Terraform in the V2V pipeline.
# The lookup only reads numbers already claimed by the selected instance.
data "external" "outbound_phone_number" {
  count = (local.deploy_connect || local.deploy_connect_resources) && var.outbound_phone_number_id == null && var.outbound_phone_number != null ? 1 : 0

  program = ["python3", "${path.module}/../../scripts/resolve-connect-phone-number.py"]

  query = {
    instance_id  = data.aws_connect_instance.target[0].id
    phone_number = var.outbound_phone_number
    region       = "us-east-1"
  }
}

locals {
  resolved_outbound_phone_number_id = var.outbound_phone_number_id != null ? var.outbound_phone_number_id : try(
    data.external.outbound_phone_number[0].result.phone_number_id,
    null
  )
}

output "resolved_outbound_phone_number_id" {
  description = "Claimed Connect phone-number UUID selected for outbound caller ID."
  value       = local.resolved_outbound_phone_number_id
}
