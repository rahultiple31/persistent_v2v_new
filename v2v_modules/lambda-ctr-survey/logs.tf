resource "aws_cloudwatch_log_group" "survey" {
  name              = "/aws/lambda/${var.function_name}"
  retention_in_days = var.log_retention_days
  tags              = local.effective_tags
}
