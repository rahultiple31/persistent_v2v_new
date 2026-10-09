resource "aws_cloudwatch_log_group" "raw" {
  name              = "/aws/lambda/${var.function_name}"
  retention_in_days = var.log_retention_days
  tags              = var.common_tags
}
