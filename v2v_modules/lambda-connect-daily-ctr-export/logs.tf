resource "aws_cloudwatch_log_group" "export" {
  name              = var.log_group_name
  retention_in_days = var.log_retention_days
  tags              = var.common_tags
}
