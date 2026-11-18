output "topic_arn" {
  description = "ARN of the alerts SNS topic."
  value       = aws_sns_topic.alerts.arn
}

output "alarm_names" {
  description = "Names of every managed alarm."
  value       = sort(keys(aws_cloudwatch_metric_alarm.this))
}

output "lambda_thresholds" {
  description = "Duration (ms) and concurrency thresholds derived for each watched Lambda."
  value = {
    for name, limits in local.lambda_limits : name => {
      timeout_seconds       = limits.timeout_seconds
      concurrency_limit     = limits.limit
      duration_threshold_ms = floor(var.threshold_ratio * limits.timeout_seconds * 1000)
      concurrency_threshold = floor(var.threshold_ratio * limits.limit)
    }
  }
}
