# Adopt the existing Connect invocation grant in the V2V Connect state.
# Skip the import when deploying another group, where the resource has count = 0.
import {
  for_each = local.deploy_connect ? {
    existing = "BTSGSD-V2V-US-conversionOfQueueMetrics/connect-bcc989e5-cd9d-494f-9cd4-434f39ccc90e"
  } : {}

  to = aws_lambda_permission.queue_metrics_connect[0]
  id = each.value
}
