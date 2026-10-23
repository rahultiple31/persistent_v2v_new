resource "aws_connect_user" "this" {
  for_each = var.create_users ? var.users : {}

  instance_id          = local.instance_id
  name                 = each.key
  routing_profile_id   = local.routing_profile_ids[each.value.routing_profile]
  security_profile_ids = [local.security_profile_ids[each.value.security_profile]]

  identity_info {
    first_name = each.value.first_name
    last_name  = each.value.last_name
  }

  phone_config {
    after_contact_work_time_limit = 0
    auto_accept                   = false
    phone_type                    = "SOFT_PHONE"
  }

  tags = merge(var.tags, { Name = each.key })
}
