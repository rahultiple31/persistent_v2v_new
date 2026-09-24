locals {
  normalized_ssm_hierarchy = trim(var.ssm_hierarchy, "/")
  ssm_hierarchy            = local.normalized_ssm_hierarchy == "" ? "" : "/${local.normalized_ssm_hierarchy}"
}

resource "aws_ssm_parameter" "this" {
  for_each = var.parameters

  name      = "${local.ssm_hierarchy}/${each.key}"
  type      = "String"
  value     = each.value
  tags      = var.common_tags
}
