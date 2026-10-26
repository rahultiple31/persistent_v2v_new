################################################################################
# CloudWatch Module
# Creates:
#   • Log group for proxy container logs (90-day retention)
#
# Mirrors CDK: PrivatePocStack > Service > logGroup
################################################################################

resource "aws_cloudwatch_log_group" "proxy" {
  name              = "/ecs/${var.stack_name}/proxy"
  retention_in_days = 90 # CDK: RetentionDays.THREE_MONTHS

  tags = {
    Name = "${var.stack_name}-proxy-logs"
  }
}
