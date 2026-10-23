# User quick connects. The FF Help Desk and HR Help Desk phone quick connects
# are managed by the connect-queue module.
locals {
  quick_connect_usernames = toset([
    var.quick_connect_mahendra_username,
    var.quick_connect_smita_username,
    var.quick_connect_govind_username,
  ])
}

# Existing users are looked up only when this module does not create them.
data "aws_connect_user" "quick_connect" {
  for_each = var.create_users ? toset([]) : local.quick_connect_usernames

  instance_id = local.instance_id
  name        = each.value
}

locals {
  quick_connect_user_ids = {
    for name in local.quick_connect_usernames :
    name => var.create_users ? aws_connect_user.this[name].user_id : data.aws_connect_user.quick_connect[name].user_id
  }
}

resource "aws_connect_quick_connect" "mahendra_kumar" {
  instance_id = local.instance_id
  name        = "Mahendra Kumar"

  quick_connect_config {
    quick_connect_type = "USER"
    user_config {
      user_id         = local.quick_connect_user_ids[var.quick_connect_mahendra_username]
      contact_flow_id = var.quick_connect_flow_id
    }
  }

  tags = merge(var.tags, { Name = "Mahendra Kumar" })
}

resource "aws_connect_quick_connect" "smita_kulkarni" {
  instance_id = local.instance_id
  name        = "Smita Kulkarni"

  quick_connect_config {
    quick_connect_type = "USER"
    user_config {
      user_id         = local.quick_connect_user_ids[var.quick_connect_smita_username]
      contact_flow_id = var.quick_connect_flow_id
    }
  }

  tags = merge(var.tags, { Name = "Smita Kulkarni" })
}

resource "aws_connect_quick_connect" "govind_khandelwal" {
  instance_id = local.instance_id
  name        = "Govind Khandelwal"

  quick_connect_config {
    quick_connect_type = "USER"
    user_config {
      user_id         = local.quick_connect_user_ids[var.quick_connect_govind_username]
      contact_flow_id = var.quick_connect_flow_id
    }
  }

  tags = merge(var.tags, { Name = "Govind Khandelwal" })
}
