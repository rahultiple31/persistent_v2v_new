data "aws_connect_instance" "selected" {
  instance_alias = var.connect_instance_alias
}

data "aws_default_tags" "current" {}

data "aws_region" "current" {}

locals {
  effective_tags = length(var.common_tags) == 0 ? data.aws_default_tags.current.tags : var.common_tags
}
