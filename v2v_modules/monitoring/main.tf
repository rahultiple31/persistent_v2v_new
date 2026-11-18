# CloudWatch alarms and their SNS topic for the V2V resources. Replaces the
# console-built ALARM-*-dev alarms (DEV-SSO resources) with the same checks on
# the V2V resources. Every target is read here by name, so a plan fails if a
# watched resource is missing; the resources themselves stay in their own
# states.
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.21.0"
    }
  }
}

# --------------------------------------------------------------------------
# Notification topic
# --------------------------------------------------------------------------
resource "aws_sns_topic" "alerts" {
  name = var.topic_name
  tags = merge(var.tags, { Name = var.topic_name })
}

# Email subscriptions stay "pending confirmation" until each recipient clicks
# the link AWS sends. Terraform cannot confirm them.
resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.alert_email_addresses)

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

# --------------------------------------------------------------------------
# Watched resources (owned by other Terraform states)
# --------------------------------------------------------------------------
data "aws_connect_instance" "this" {
  instance_alias = var.connect_instance_alias
}

data "aws_lambda_function" "watched" {
  for_each = var.lambda_alarms

  function_name = each.key
}

data "aws_connect_contact_flow" "watched" {
  for_each = var.contact_flow_alarms

  instance_id = data.aws_connect_instance.this.id
  name        = each.key
}

data "aws_connect_queue" "watched" {
  for_each = var.queue_alarms

  instance_id = data.aws_connect_instance.this.id
  name        = each.key
}

data "aws_cloudformation_stack" "gateway" {
  name = var.gateway_stack_name
}

# --------------------------------------------------------------------------
# Alarm catalog
# --------------------------------------------------------------------------
locals {
  percent     = format("%d", var.threshold_ratio * 100)
  instance_id = data.aws_connect_instance.this.id
  gateway_arn = data.aws_cloudformation_stack.gateway.outputs["GatewayArn"]

  # Settings shared by every alarm. Single-metric alarms override the nulls.
  base = {
    namespace          = null
    metric_name        = null
    statistic          = null
    extended_statistic = null
    dimensions         = {}
    error_rate         = null
  }

  lambda_limits = {
    for name, fn in data.aws_lambda_function.watched : name => {
      timeout_seconds = fn.timeout
      # -1 or 0 means no reserved concurrency: use the account limit.
      reserved = try(fn.reserved_concurrent_executions, -1) > 0 ? fn.reserved_concurrent_executions : null
      limit    = try(fn.reserved_concurrent_executions, -1) > 0 ? fn.reserved_concurrent_executions : var.lambda_account_concurrency_limit
    }
  }

  lambda_alarms = merge([
    for name, cfg in var.lambda_alarms : {
      "ALARM-Medium-Lambda-${cfg.alarm_label}-ConcurrentExecutions${var.alarm_name_suffix}" = merge(local.base, {
        priority            = "Medium"
        description         = "[Medium] Concurrency above ${local.percent} percent of ${local.lambda_limits[name].reserved == null ? "the account limit" : "reserved concurrency"} (${local.lambda_limits[name].limit}) - ${name}"
        namespace           = "AWS/Lambda"
        metric_name         = "ConcurrentExecutions"
        statistic           = "Maximum"
        dimensions          = { FunctionName = data.aws_lambda_function.watched[name].function_name }
        period              = 60
        evaluation_periods  = 1
        datapoints_to_alarm = 1
        comparison_operator = "GreaterThanThreshold"
        threshold           = floor(var.threshold_ratio * local.lambda_limits[name].limit)
      })
      "ALARM-High-Lambda-${cfg.alarm_label}-Duration${var.alarm_name_suffix}" = merge(local.base, {
        priority            = "High"
        description         = "[High] p99 duration above ${local.percent} percent of the ${local.lambda_limits[name].timeout_seconds} s timeout - ${name}"
        namespace           = "AWS/Lambda"
        metric_name         = "Duration"
        extended_statistic  = "p99"
        dimensions          = { FunctionName = data.aws_lambda_function.watched[name].function_name }
        period              = 60
        evaluation_periods  = 3
        datapoints_to_alarm = 3
        comparison_operator = "GreaterThanThreshold"
        threshold           = floor(var.threshold_ratio * local.lambda_limits[name].timeout_seconds * 1000)
      })
      "ALARM-Critical-Lambda-${cfg.alarm_label}-Errors${var.alarm_name_suffix}" = merge(local.base, {
        priority            = "Critical"
        description         = "[Critical] Lambda error rate above 5 percent - ${name}"
        error_rate          = data.aws_lambda_function.watched[name].function_name
        period              = 60
        evaluation_periods  = 2
        datapoints_to_alarm = 2
        comparison_operator = "GreaterThanThreshold"
        threshold           = 5
      })
      "ALARM-High-Lambda-${cfg.alarm_label}-Throttles${var.alarm_name_suffix}" = merge(local.base, {
        priority            = "High"
        description         = "[High] Lambda throttled - ${name}"
        namespace           = "AWS/Lambda"
        metric_name         = "Throttles"
        statistic           = "Sum"
        dimensions          = { FunctionName = data.aws_lambda_function.watched[name].function_name }
        period              = 60
        evaluation_periods  = 1
        datapoints_to_alarm = 1
        comparison_operator = "GreaterThanOrEqualToThreshold"
        threshold           = 1
      })
    }
  ]...)

  contact_flow_alarms = merge([
    for name, cfg in var.contact_flow_alarms : {
      "ALARM-High-Connect-${cfg.alarm_label}-ContactFlowErrors${var.alarm_name_suffix}" = merge(local.base, {
        priority            = "High"
        description         = "Error branch taken - logic/integration failure in the IVR (e.g. failed Lambda / AgentCore tool call). Flow: ${name}"
        namespace           = "AWS/Connect"
        metric_name         = "ContactFlowErrors"
        statistic           = "Sum"
        dimensions          = { InstanceId = local.instance_id, MetricGroup = "ContactFlow", ContactFlowName = data.aws_connect_contact_flow.watched[name].name }
        period              = 300
        evaluation_periods  = 1
        datapoints_to_alarm = 1
        comparison_operator = "GreaterThanOrEqualToThreshold"
        threshold           = 1
      })
      "ALARM-Critical-Connect-${cfg.alarm_label}-ContactFlowFatalErrors${var.alarm_name_suffix}" = merge(local.base, {
        priority            = "Critical"
        description         = "Flow failed to execute due to a system error - hard break in the IVR journey. Notify immediately. Flow: ${name}"
        namespace           = "AWS/Connect"
        metric_name         = "ContactFlowFatalErrors"
        statistic           = "Sum"
        dimensions          = { InstanceId = local.instance_id, MetricGroup = "ContactFlow", ContactFlowName = data.aws_connect_contact_flow.watched[name].name }
        period              = 60
        evaluation_periods  = 1
        datapoints_to_alarm = 1
        comparison_operator = "GreaterThanOrEqualToThreshold"
        threshold           = 1
      })
    }
  ]...)

  queue_alarms = {
    for name, cfg in var.queue_alarms :
    "ALARM-Medium-Connect-${cfg.alarm_label}-QueueCapacityExceededError${var.alarm_name_suffix}" => merge(local.base, {
      priority            = "Medium"
      description         = "Calls rejected because the queue was full - ${name}"
      namespace           = "AWS/Connect"
      metric_name         = "QueueCapacityExceededError"
      statistic           = "Sum"
      dimensions          = { InstanceId = local.instance_id, MetricGroup = "Queue", QueueName = data.aws_connect_queue.watched[name].name }
      period              = 300
      evaluation_periods  = 1
      datapoints_to_alarm = 1
      comparison_operator = "GreaterThanOrEqualToThreshold"
      threshold           = 1
    })
  }

  # Instance-level alarms: same metrics, dimensions and thresholds as the console alarms.
  instance_alarm_definitions = {
    CallRecordingUploadError       = { priority = "High", statistic = "Sum", dimensions = { MetricGroup = "CallRecordings" }, period = 300, evaluations = 1, comparison = "GreaterThanOrEqualToThreshold", threshold = 1, description = "High: Recording S3 upload failures - compliance / QA risk." }
    CallsBreachingConcurrencyQuota = { priority = "High", statistic = "Sum", dimensions = {}, period = 300, evaluations = 1, comparison = "GreaterThanOrEqualToThreshold", threshold = 1, description = "High: Voice calls exceeding the concurrent-calls quota - callers blocked." }
    ConcurrentCallsPercentage      = { priority = "Medium", statistic = "Maximum", dimensions = { MetricGroup = "VoiceCalls" }, period = 300, evaluations = 1, comparison = "GreaterThanThreshold", threshold = 80, description = "Medium: Approaching concurrent-call quota - early warning (alert at 80% of quota)." }
    MisconfiguredPhoneNumbers      = { priority = "Medium", statistic = "Sum", dimensions = {}, period = 300, evaluations = 1, comparison = "GreaterThanOrEqualToThreshold", threshold = 1, description = "Medium: Calls to numbers with no flow association - misconfiguration." }
    MissedCalls                    = { priority = "Medium", statistic = "Sum", dimensions = { MetricGroup = "VoiceCalls" }, period = 300, evaluations = 3, comparison = "GreaterThanOrEqualToThreshold", threshold = 5, description = "Medium: Calls not answered by an agent within 20s - service-level degradation." }
    ThrottledCalls                 = { priority = "High", statistic = "Sum", dimensions = {}, period = 300, evaluations = 1, comparison = "GreaterThanOrEqualToThreshold", threshold = 1, description = "High: Calls rejected for exceeding calls-per-second quota. Request quota increase if recurring." }
    ToInstancePacketLossRate       = { priority = "Medium", statistic = "Average", dimensions = { Participant = "Agent", "Type of Connection" = "WebRTC", "Stream Type" = "Voice" }, period = 60, evaluations = 3, comparison = "GreaterThanThreshold", threshold = 0.02, description = "Medium: WebRTC packet loss above 2% sustained - voice-quality degradation affecting IVR comprehension." }
  }

  instance_alarms = {
    for metric, cfg in local.instance_alarm_definitions :
    "ALARM-${cfg.priority}-Connect-Instance-${metric}${var.alarm_name_suffix}" => merge(local.base, {
      priority            = cfg.priority
      description         = cfg.description
      namespace           = "AWS/Connect"
      metric_name         = metric
      statistic           = cfg.statistic
      dimensions          = merge({ InstanceId = local.instance_id }, cfg.dimensions)
      period              = cfg.period
      evaluation_periods  = cfg.evaluations
      datapoints_to_alarm = cfg.evaluations
      comparison_operator = cfg.comparison
      threshold           = cfg.threshold
    })
  }

  gateway_alarm_definitions = {
    LatencyP99   = { priority = "High", metric = "Latency", statistic = null, extended = "p99", evaluations = 3, comparison = "GreaterThanThreshold", threshold = 1000, description = "High: Gateway initial-response latency p99 > 1 s - impacts caller turn-around." }
    SystemErrors = { priority = "Critical", metric = "SystemErrors", statistic = "Sum", extended = null, evaluations = 1, comparison = "GreaterThanThreshold", threshold = 5, description = "Critical: 5xx from the AgentCore gateway (> 5 in 5 min) - ServiceNow/Nexthink MCP integration failing." }
    Throttles    = { priority = "High", metric = "Throttles", statistic = "Sum", extended = null, evaluations = 1, comparison = "GreaterThanOrEqualToThreshold", threshold = 1, description = "High: 429s - requests throttled; tool calls from the IVR/Lambda dropped." }
  }

  gateway_alarms = {
    for label, cfg in local.gateway_alarm_definitions :
    "ALARM-${cfg.priority}-AgentCoreGW-${label}${var.alarm_name_suffix}" => merge(local.base, {
      priority            = cfg.priority
      description         = cfg.description
      namespace           = "AWS/Bedrock-AgentCore"
      metric_name         = cfg.metric
      statistic           = cfg.statistic
      extended_statistic  = cfg.extended
      dimensions          = merge({ Resource = local.gateway_arn }, var.gateway_metric_dimensions)
      period              = 300
      evaluation_periods  = cfg.evaluations
      datapoints_to_alarm = cfg.evaluations
      comparison_operator = cfg.comparison
      threshold           = cfg.threshold
    })
  }

  alarms = merge(
    local.lambda_alarms,
    local.contact_flow_alarms,
    local.queue_alarms,
    local.instance_alarms,
    local.gateway_alarms,
  )
}

# --------------------------------------------------------------------------
# Alarms
# --------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "this" {
  for_each = local.alarms

  alarm_name          = each.key
  alarm_description   = each.value.description
  comparison_operator = each.value.comparison_operator
  threshold           = each.value.threshold
  evaluation_periods  = each.value.evaluation_periods
  datapoints_to_alarm = each.value.datapoints_to_alarm
  treat_missing_data  = "notBreaching"
  actions_enabled     = true
  alarm_actions       = [aws_sns_topic.alerts.arn]

  # Single-metric alarms.
  namespace          = each.value.error_rate == null ? each.value.namespace : null
  metric_name        = each.value.error_rate == null ? each.value.metric_name : null
  statistic          = each.value.error_rate == null ? each.value.statistic : null
  extended_statistic = each.value.error_rate == null ? each.value.extended_statistic : null
  period             = each.value.error_rate == null ? each.value.period : null
  dimensions         = each.value.error_rate == null ? each.value.dimensions : null

  # Lambda error rate: errors as a percentage of invocations, 0 when idle.
  dynamic "metric_query" {
    for_each = each.value.error_rate == null ? [] : ["rate"]

    content {
      id          = "rate"
      expression  = "IF(inv>0,100*err/inv,0)"
      label       = "ErrorRate%"
      return_data = true
    }
  }

  dynamic "metric_query" {
    for_each = each.value.error_rate == null ? {} : { err = "Errors", inv = "Invocations" }

    content {
      id          = metric_query.key
      return_data = false

      metric {
        namespace   = "AWS/Lambda"
        metric_name = metric_query.value
        period      = each.value.period
        stat        = "Sum"
        dimensions  = { FunctionName = each.value.error_rate }
      }
    }
  }

  tags = merge(var.tags, { Priority = each.value.priority })
}
