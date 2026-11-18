mock_provider "aws" {
  mock_data "aws_connect_instance" {
    defaults = {
      id = "bcc989e5-cd9d-494f-9cd4-434f39ccc90e"
    }
  }

  mock_data "aws_lambda_function" {
    defaults = {
      timeout                        = 8
      reserved_concurrent_executions = -1
    }
  }

  mock_data "aws_cloudformation_stack" {
    defaults = {
      outputs = {
        GatewayArn = "arn:aws:bedrock-agentcore:us-east-1:518902362956:gateway/btsgsd-v2v-us-gateway-quick-start-rjqs1usbt7"
      }
    }
  }

  mock_resource "aws_sns_topic" {
    defaults = {
      arn = "arn:aws:sns:us-east-1:518902362956:BTSGSD-V2V-US-alerts"
    }
  }
}

# Data lookups return the requested name, as the provider does.
override_data {
  target = data.aws_lambda_function.watched["BTSGSD-V2V-US-silence_guard"]
  values = {
    function_name                  = "BTSGSD-V2V-US-silence_guard"
    timeout                        = 3
    reserved_concurrent_executions = -1
  }
}

override_data {
  target = data.aws_lambda_function.watched["BTSGSD-V2V-US-SNOW"]
  values = {
    function_name                  = "BTSGSD-V2V-US-SNOW"
    timeout                        = 8
    reserved_concurrent_executions = 200
  }
}

override_data {
  target = data.aws_lambda_function.watched["BTSGSD-V2V-US-voicemail-Transcriber"]
  values = {
    function_name                  = "BTSGSD-V2V-US-voicemail-Transcriber"
    timeout                        = 848
    reserved_concurrent_executions = -1
  }
}

override_data {
  target = data.aws_connect_contact_flow.watched["BTSGSD-V2V-US-Views"]
  values = {
    name = "BTSGSD-V2V-US-Views"
  }
}

override_data {
  target = data.aws_connect_queue.watched["BTSGSD-V2V-US-DEV SSO-US-MAIN-QUEUE"]
  values = {
    name = "BTSGSD-V2V-US-DEV SSO-US-MAIN-QUEUE"
  }
}

variables {
  topic_name             = "BTSGSD-V2V-US-alerts"
  alert_email_addresses  = ["first.person@example.com", "second.person@example.com"]
  connect_instance_alias = "btsgsd-dev-v2v-poc-us-east-1"
  gateway_stack_name     = "BTSGSD-V2V-US-AgentCore-DefaultGateway"
  tags                   = { App = "AbbVie-ServiceDesk", Environment = "v2v" }

  lambda_alarms = {
    "BTSGSD-V2V-US-connect-daily-ctr-consolidation"  = { alarm_label = "btsgsd-dev-us-east-1-connect-daily-ctr-consolidation" }
    "BTSGSD-V2V-US-connect-daily-ctr-export"         = { alarm_label = "btsgsd-dev-us-east-1-connect-daily-ctr-export" }
    "BTSGSD-V2V-US-conversionOfQueueMetrics"         = { alarm_label = "conversionOfQueueMetrics-dev" }
    "BTSGSD-V2V-US-CTR-Survey"                       = { alarm_label = "btsgsd-dev-us-east-1-CTR-Survey" }
    "BTSGSD-V2V-US-lex-QueueFlow-Callback"           = { alarm_label = "BTSGSD-lex-QueueFlow-Callback-dev" }
    "BTSGSD-V2V-US-lex-yesNo"                        = { alarm_label = "BTSGSD-lex-yesNo-dev" }
    "BTSGSD-V2V-US-Nextthink_Handoff"                = { alarm_label = "Nextthink_Handoff_btsgsd-dev" }
    "BTSGSD-V2V-US-ServiceNow_Interaction"           = { alarm_label = "ServiceNow_Interaction_btsgsd-dev" }
    "BTSGSD-V2V-US-silence_guard"                    = { alarm_label = "NonSSO-silence_guard-dev" }
    "BTSGSD-V2V-US-SNOW"                             = { alarm_label = "SNOW_btsgsd-dev" }
    "BTSGSD-V2V-US-UpdateSessionAttributes"          = { alarm_label = "UpdateSessionAttributes-dev" }
    "BTSGSD-V2V-US-views"                            = { alarm_label = "BTSGSD-Abbvie-views-Dev" }
    "BTSGSD-V2V-US-voicemail-GuidedTaskPresigner"    = { alarm_label = "VMX3-GuidedTaskPresigner-btsgsd-dev-us-east-1" }
    "BTSGSD-V2V-US-voicemail-Packager"               = { alarm_label = "VMX3-Packager-btsgsd-dev-us-east-1" }
    "BTSGSD-V2V-US-voicemail-RecordingProcessor"     = { alarm_label = "VMX3-RecordingProcessor-btsgsd-dev-us-east-1" }
    "BTSGSD-V2V-US-voicemail-TranscribeErrorHandler" = { alarm_label = "VMX3-TranscribeErrorHandler-btsgsd-dev-us-east-1" }
    "BTSGSD-V2V-US-voicemail-Transcriber"            = { alarm_label = "VMX3-Transcriber-btsgsd-dev-us-east-1" }
    "BTSGSD-V2V-US-voicemail-VoicemailTimestamper"   = { alarm_label = "VMX3-VoicemailTimestamper-btsgsd-dev-us-east-1" }
  }
  contact_flow_alarms = {
    "BTSGSD-V2V-US-btsgsd_HR"                = { alarm_label = "btsgsd_HR" }
    "BTSGSD-V2V-US-HR"                       = { alarm_label = "btsgsd-dev-us-east-1-HR" }
    "BTSGSD-V2V-US-Main-IB-Flow"             = { alarm_label = "btsgsd-Main-IB-Flow" }
    "BTSGSD-V2V-US-placeholder-inbound-flow" = { alarm_label = "btsgsd-dev-us-east-1-placeholder-inbound-flow" }
    "BTSGSD-V2V-US-stdgsd_Fieldforce_Flow"   = { alarm_label = "stdgsd_Fieldforce_Flow" }
    "BTSGSD-V2V-US-SurveyFlow"               = { alarm_label = "BTSGSD-AIAgent-SurveyFlow" }
    "BTSGSD-V2V-US-Views"                    = { alarm_label = "AbbVie_Views" }
    "BTSGSD-V2V-US-VoicemailFlow"            = { alarm_label = "btsgsd-VoicemailFlow" }
  }
  queue_alarms = {
    "BTSGSD-V2V-LATAM-MAIN-QUEUE"         = { alarm_label = "BTSGSD-DEV-SSO-LATAM-MAIN-QUEUE" }
    "BTSGSD-V2V-LATAM-OUT-QUEUE"          = { alarm_label = "BTSGSD-DEV-SSO-LATAM-OUT-QUEUE" }
    "BTSGSD-V2V-US-DEV SSO-US-MAIN-QUEUE" = { alarm_label = "BTSGSD-DEV-SSO-US-MAIN-QUEUE-SPACE" }
    "BTSGSD-V2V-US-MAIN-QUEUE"            = { alarm_label = "BTSGSD-DEV-SSO-US-MAIN-QUEUE" }
    "BTSGSD-V2V-US-OUT-QUEUE"             = { alarm_label = "BTSGSD-DEV-SSO-US-OUT-QUEUE" }
    "BTSGSD-V2V-US-VM-QUEUE"              = { alarm_label = "BTSGSD-DEV-SSO-US-VM-QUEUE" }
  }
}

run "alarm_names_are_the_console_names_with_the_v2v_suffix" {
  command = plan

  assert {
    condition = output.alarm_names == sort([
      "ALARM-Critical-AgentCoreGW-SystemErrors-v2v",
      "ALARM-Critical-Connect-AbbVie_Views-ContactFlowFatalErrors-v2v",
      "ALARM-Critical-Connect-BTSGSD-AIAgent-SurveyFlow-ContactFlowFatalErrors-v2v",
      "ALARM-Critical-Connect-btsgsd-Main-IB-Flow-ContactFlowFatalErrors-v2v",
      "ALARM-Critical-Connect-btsgsd-VoicemailFlow-ContactFlowFatalErrors-v2v",
      "ALARM-Critical-Connect-btsgsd-dev-us-east-1-HR-ContactFlowFatalErrors-v2v",
      "ALARM-Critical-Connect-btsgsd-dev-us-east-1-placeholder-inbound-flow-ContactFlowFatalErrors-v2v",
      "ALARM-Critical-Connect-btsgsd_HR-ContactFlowFatalErrors-v2v",
      "ALARM-Critical-Connect-stdgsd_Fieldforce_Flow-ContactFlowFatalErrors-v2v",
      "ALARM-Critical-Lambda-BTSGSD-Abbvie-views-Dev-Errors-v2v",
      "ALARM-Critical-Lambda-BTSGSD-lex-QueueFlow-Callback-dev-Errors-v2v",
      "ALARM-Critical-Lambda-BTSGSD-lex-yesNo-dev-Errors-v2v",
      "ALARM-Critical-Lambda-Nextthink_Handoff_btsgsd-dev-Errors-v2v",
      "ALARM-Critical-Lambda-NonSSO-silence_guard-dev-Errors-v2v",
      "ALARM-Critical-Lambda-SNOW_btsgsd-dev-Errors-v2v",
      "ALARM-Critical-Lambda-ServiceNow_Interaction_btsgsd-dev-Errors-v2v",
      "ALARM-Critical-Lambda-UpdateSessionAttributes-dev-Errors-v2v",
      "ALARM-Critical-Lambda-VMX3-GuidedTaskPresigner-btsgsd-dev-us-east-1-Errors-v2v",
      "ALARM-Critical-Lambda-VMX3-Packager-btsgsd-dev-us-east-1-Errors-v2v",
      "ALARM-Critical-Lambda-VMX3-RecordingProcessor-btsgsd-dev-us-east-1-Errors-v2v",
      "ALARM-Critical-Lambda-VMX3-TranscribeErrorHandler-btsgsd-dev-us-east-1-Errors-v2v",
      "ALARM-Critical-Lambda-VMX3-Transcriber-btsgsd-dev-us-east-1-Errors-v2v",
      "ALARM-Critical-Lambda-VMX3-VoicemailTimestamper-btsgsd-dev-us-east-1-Errors-v2v",
      "ALARM-Critical-Lambda-btsgsd-dev-us-east-1-CTR-Survey-Errors-v2v",
      "ALARM-Critical-Lambda-btsgsd-dev-us-east-1-connect-daily-ctr-consolidation-Errors-v2v",
      "ALARM-Critical-Lambda-btsgsd-dev-us-east-1-connect-daily-ctr-export-Errors-v2v",
      "ALARM-Critical-Lambda-conversionOfQueueMetrics-dev-Errors-v2v",
      "ALARM-High-AgentCoreGW-LatencyP99-v2v",
      "ALARM-High-AgentCoreGW-Throttles-v2v",
      "ALARM-High-Connect-AbbVie_Views-ContactFlowErrors-v2v",
      "ALARM-High-Connect-BTSGSD-AIAgent-SurveyFlow-ContactFlowErrors-v2v",
      "ALARM-High-Connect-Instance-CallRecordingUploadError-v2v",
      "ALARM-High-Connect-Instance-CallsBreachingConcurrencyQuota-v2v",
      "ALARM-High-Connect-Instance-ThrottledCalls-v2v",
      "ALARM-High-Connect-btsgsd-Main-IB-Flow-ContactFlowErrors-v2v",
      "ALARM-High-Connect-btsgsd-VoicemailFlow-ContactFlowErrors-v2v",
      "ALARM-High-Connect-btsgsd-dev-us-east-1-HR-ContactFlowErrors-v2v",
      "ALARM-High-Connect-btsgsd-dev-us-east-1-placeholder-inbound-flow-ContactFlowErrors-v2v",
      "ALARM-High-Connect-btsgsd_HR-ContactFlowErrors-v2v",
      "ALARM-High-Connect-stdgsd_Fieldforce_Flow-ContactFlowErrors-v2v",
      "ALARM-High-Lambda-BTSGSD-Abbvie-views-Dev-Duration-v2v",
      "ALARM-High-Lambda-BTSGSD-Abbvie-views-Dev-Throttles-v2v",
      "ALARM-High-Lambda-BTSGSD-lex-QueueFlow-Callback-dev-Duration-v2v",
      "ALARM-High-Lambda-BTSGSD-lex-QueueFlow-Callback-dev-Throttles-v2v",
      "ALARM-High-Lambda-BTSGSD-lex-yesNo-dev-Duration-v2v",
      "ALARM-High-Lambda-BTSGSD-lex-yesNo-dev-Throttles-v2v",
      "ALARM-High-Lambda-Nextthink_Handoff_btsgsd-dev-Duration-v2v",
      "ALARM-High-Lambda-Nextthink_Handoff_btsgsd-dev-Throttles-v2v",
      "ALARM-High-Lambda-NonSSO-silence_guard-dev-Duration-v2v",
      "ALARM-High-Lambda-NonSSO-silence_guard-dev-Throttles-v2v",
      "ALARM-High-Lambda-SNOW_btsgsd-dev-Duration-v2v",
      "ALARM-High-Lambda-SNOW_btsgsd-dev-Throttles-v2v",
      "ALARM-High-Lambda-ServiceNow_Interaction_btsgsd-dev-Duration-v2v",
      "ALARM-High-Lambda-ServiceNow_Interaction_btsgsd-dev-Throttles-v2v",
      "ALARM-High-Lambda-UpdateSessionAttributes-dev-Duration-v2v",
      "ALARM-High-Lambda-UpdateSessionAttributes-dev-Throttles-v2v",
      "ALARM-High-Lambda-VMX3-GuidedTaskPresigner-btsgsd-dev-us-east-1-Duration-v2v",
      "ALARM-High-Lambda-VMX3-GuidedTaskPresigner-btsgsd-dev-us-east-1-Throttles-v2v",
      "ALARM-High-Lambda-VMX3-Packager-btsgsd-dev-us-east-1-Duration-v2v",
      "ALARM-High-Lambda-VMX3-Packager-btsgsd-dev-us-east-1-Throttles-v2v",
      "ALARM-High-Lambda-VMX3-RecordingProcessor-btsgsd-dev-us-east-1-Duration-v2v",
      "ALARM-High-Lambda-VMX3-RecordingProcessor-btsgsd-dev-us-east-1-Throttles-v2v",
      "ALARM-High-Lambda-VMX3-TranscribeErrorHandler-btsgsd-dev-us-east-1-Duration-v2v",
      "ALARM-High-Lambda-VMX3-TranscribeErrorHandler-btsgsd-dev-us-east-1-Throttles-v2v",
      "ALARM-High-Lambda-VMX3-Transcriber-btsgsd-dev-us-east-1-Duration-v2v",
      "ALARM-High-Lambda-VMX3-Transcriber-btsgsd-dev-us-east-1-Throttles-v2v",
      "ALARM-High-Lambda-VMX3-VoicemailTimestamper-btsgsd-dev-us-east-1-Duration-v2v",
      "ALARM-High-Lambda-VMX3-VoicemailTimestamper-btsgsd-dev-us-east-1-Throttles-v2v",
      "ALARM-High-Lambda-btsgsd-dev-us-east-1-CTR-Survey-Duration-v2v",
      "ALARM-High-Lambda-btsgsd-dev-us-east-1-CTR-Survey-Throttles-v2v",
      "ALARM-High-Lambda-btsgsd-dev-us-east-1-connect-daily-ctr-consolidation-Duration-v2v",
      "ALARM-High-Lambda-btsgsd-dev-us-east-1-connect-daily-ctr-consolidation-Throttles-v2v",
      "ALARM-High-Lambda-btsgsd-dev-us-east-1-connect-daily-ctr-export-Duration-v2v",
      "ALARM-High-Lambda-btsgsd-dev-us-east-1-connect-daily-ctr-export-Throttles-v2v",
      "ALARM-High-Lambda-conversionOfQueueMetrics-dev-Duration-v2v",
      "ALARM-High-Lambda-conversionOfQueueMetrics-dev-Throttles-v2v",
      "ALARM-Medium-Connect-BTSGSD-DEV-SSO-LATAM-MAIN-QUEUE-QueueCapacityExceededError-v2v",
      "ALARM-Medium-Connect-BTSGSD-DEV-SSO-LATAM-OUT-QUEUE-QueueCapacityExceededError-v2v",
      "ALARM-Medium-Connect-BTSGSD-DEV-SSO-US-MAIN-QUEUE-QueueCapacityExceededError-v2v",
      "ALARM-Medium-Connect-BTSGSD-DEV-SSO-US-MAIN-QUEUE-SPACE-QueueCapacityExceededError-v2v",
      "ALARM-Medium-Connect-BTSGSD-DEV-SSO-US-OUT-QUEUE-QueueCapacityExceededError-v2v",
      "ALARM-Medium-Connect-BTSGSD-DEV-SSO-US-VM-QUEUE-QueueCapacityExceededError-v2v",
      "ALARM-Medium-Connect-Instance-ConcurrentCallsPercentage-v2v",
      "ALARM-Medium-Connect-Instance-MisconfiguredPhoneNumbers-v2v",
      "ALARM-Medium-Connect-Instance-MissedCalls-v2v",
      "ALARM-Medium-Connect-Instance-ToInstancePacketLossRate-v2v",
      "ALARM-Medium-Lambda-BTSGSD-Abbvie-views-Dev-ConcurrentExecutions-v2v",
      "ALARM-Medium-Lambda-BTSGSD-lex-QueueFlow-Callback-dev-ConcurrentExecutions-v2v",
      "ALARM-Medium-Lambda-BTSGSD-lex-yesNo-dev-ConcurrentExecutions-v2v",
      "ALARM-Medium-Lambda-Nextthink_Handoff_btsgsd-dev-ConcurrentExecutions-v2v",
      "ALARM-Medium-Lambda-NonSSO-silence_guard-dev-ConcurrentExecutions-v2v",
      "ALARM-Medium-Lambda-SNOW_btsgsd-dev-ConcurrentExecutions-v2v",
      "ALARM-Medium-Lambda-ServiceNow_Interaction_btsgsd-dev-ConcurrentExecutions-v2v",
      "ALARM-Medium-Lambda-UpdateSessionAttributes-dev-ConcurrentExecutions-v2v",
      "ALARM-Medium-Lambda-VMX3-GuidedTaskPresigner-btsgsd-dev-us-east-1-ConcurrentExecutions-v2v",
      "ALARM-Medium-Lambda-VMX3-Packager-btsgsd-dev-us-east-1-ConcurrentExecutions-v2v",
      "ALARM-Medium-Lambda-VMX3-RecordingProcessor-btsgsd-dev-us-east-1-ConcurrentExecutions-v2v",
      "ALARM-Medium-Lambda-VMX3-TranscribeErrorHandler-btsgsd-dev-us-east-1-ConcurrentExecutions-v2v",
      "ALARM-Medium-Lambda-VMX3-Transcriber-btsgsd-dev-us-east-1-ConcurrentExecutions-v2v",
      "ALARM-Medium-Lambda-VMX3-VoicemailTimestamper-btsgsd-dev-us-east-1-ConcurrentExecutions-v2v",
      "ALARM-Medium-Lambda-btsgsd-dev-us-east-1-CTR-Survey-ConcurrentExecutions-v2v",
      "ALARM-Medium-Lambda-btsgsd-dev-us-east-1-connect-daily-ctr-consolidation-ConcurrentExecutions-v2v",
      "ALARM-Medium-Lambda-btsgsd-dev-us-east-1-connect-daily-ctr-export-ConcurrentExecutions-v2v",
      "ALARM-Medium-Lambda-conversionOfQueueMetrics-dev-ConcurrentExecutions-v2v",
    ])
    error_message = "Every CSV alarm except the deleted primary queue must exist, named as the console alarm with -dev replaced by -v2v."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.this) == 104 && !contains(output.alarm_names, "ALARM-Medium-Connect-btsgsd-dev-us-east-1-primary-queue-QueueCapacityExceededError-v2v")
    error_message = "The primary queue was deleted on Nov 6; its alarm must not be created."
  }
}

run "every_alarm_notifies_the_new_topic_and_treats_missing_data_as_ok" {
  command = apply

  assert {
    condition = alltrue([
      for alarm in aws_cloudwatch_metric_alarm.this :
      alarm.alarm_actions == toset([aws_sns_topic.alerts.arn]) && alarm.treat_missing_data == "notBreaching" && alarm.actions_enabled
    ])
    error_message = "All alarms must notify the Terraform topic, enabled, with missing data treated as not breaching."
  }

  assert {
    condition = (
      aws_sns_topic.alerts.name == "BTSGSD-V2V-US-alerts" &&
      length(aws_sns_topic_subscription.email) == 2 &&
      alltrue([for sub in aws_sns_topic_subscription.email : sub.protocol == "email" && sub.topic_arn == aws_sns_topic.alerts.arn])
    )
    error_message = "One email subscription per address on the alerts topic."
  }
}

run "lambda_thresholds_follow_the_timeout_and_concurrency_of_each_v2v_function" {
  command = plan

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.this["ALARM-High-Lambda-NonSSO-silence_guard-dev-Duration-v2v"].threshold == 2400 &&
      aws_cloudwatch_metric_alarm.this["ALARM-High-Lambda-NonSSO-silence_guard-dev-Duration-v2v"].extended_statistic == "p99" &&
      aws_cloudwatch_metric_alarm.this["ALARM-High-Lambda-NonSSO-silence_guard-dev-Duration-v2v"].dimensions["FunctionName"] == "BTSGSD-V2V-US-silence_guard" &&
      aws_cloudwatch_metric_alarm.this["ALARM-High-Lambda-VMX3-Transcriber-btsgsd-dev-us-east-1-Duration-v2v"].threshold == 678400 &&
      aws_cloudwatch_metric_alarm.this["ALARM-Medium-Lambda-NonSSO-silence_guard-dev-ConcurrentExecutions-v2v"].threshold == 800 &&
      aws_cloudwatch_metric_alarm.this["ALARM-Medium-Lambda-SNOW_btsgsd-dev-ConcurrentExecutions-v2v"].threshold == 160
    )
    error_message = "Duration is 80% of the V2V timeout; concurrency is 80% of reserved concurrency, or of the account limit when none is reserved."
  }

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.this["ALARM-High-Lambda-SNOW_btsgsd-dev-Duration-v2v"].period == 60 &&
      aws_cloudwatch_metric_alarm.this["ALARM-High-Lambda-SNOW_btsgsd-dev-Duration-v2v"].evaluation_periods == 3 &&
      aws_cloudwatch_metric_alarm.this["ALARM-High-Lambda-SNOW_btsgsd-dev-Duration-v2v"].datapoints_to_alarm == 3 &&
      aws_cloudwatch_metric_alarm.this["ALARM-High-Lambda-SNOW_btsgsd-dev-Throttles-v2v"].comparison_operator == "GreaterThanOrEqualToThreshold" &&
      aws_cloudwatch_metric_alarm.this["ALARM-High-Lambda-SNOW_btsgsd-dev-Throttles-v2v"].statistic == "Sum"
    )
    error_message = "Lambda alarm periods, evaluations and operators must match the console alarms."
  }
}

run "lambda_error_rate_is_errors_over_invocations" {
  command = plan

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.this["ALARM-Critical-Lambda-SNOW_btsgsd-dev-Errors-v2v"].metric_name == null &&
      length(aws_cloudwatch_metric_alarm.this["ALARM-Critical-Lambda-SNOW_btsgsd-dev-Errors-v2v"].metric_query) == 3 &&
      aws_cloudwatch_metric_alarm.this["ALARM-Critical-Lambda-SNOW_btsgsd-dev-Errors-v2v"].threshold == 5 &&
      aws_cloudwatch_metric_alarm.this["ALARM-Critical-Lambda-SNOW_btsgsd-dev-Errors-v2v"].evaluation_periods == 2 &&
      contains([for q in aws_cloudwatch_metric_alarm.this["ALARM-Critical-Lambda-SNOW_btsgsd-dev-Errors-v2v"].metric_query : q.expression], "IF(inv>0,100*err/inv,0)") &&
      toset(flatten([for q in aws_cloudwatch_metric_alarm.this["ALARM-Critical-Lambda-SNOW_btsgsd-dev-Errors-v2v"].metric_query : [for m in q.metric : m.dimensions["FunctionName"]]])) == toset(["BTSGSD-V2V-US-SNOW"])
    )
    error_message = "The error-rate alarm must divide Errors by Invocations of the V2V function, as the console alarms do."
  }
}

run "connect_alarms_watch_the_v2v_instance_flows_and_queues" {
  command = plan

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.this["ALARM-High-Connect-AbbVie_Views-ContactFlowErrors-v2v"].dimensions == tomap({
        InstanceId      = "bcc989e5-cd9d-494f-9cd4-434f39ccc90e"
        MetricGroup     = "ContactFlow"
        ContactFlowName = "BTSGSD-V2V-US-Views"
      }) &&
      aws_cloudwatch_metric_alarm.this["ALARM-Medium-Connect-BTSGSD-DEV-SSO-US-MAIN-QUEUE-SPACE-QueueCapacityExceededError-v2v"].dimensions["QueueName"] == "BTSGSD-V2V-US-DEV SSO-US-MAIN-QUEUE" &&
      aws_cloudwatch_metric_alarm.this["ALARM-Medium-Connect-Instance-ToInstancePacketLossRate-v2v"].dimensions == tomap({
        InstanceId           = "bcc989e5-cd9d-494f-9cd4-434f39ccc90e"
        Participant          = "Agent"
        "Type of Connection" = "WebRTC"
        "Stream Type"        = "Voice"
      }) &&
      aws_cloudwatch_metric_alarm.this["ALARM-Medium-Connect-Instance-ToInstancePacketLossRate-v2v"].threshold == 0.02 &&
      aws_cloudwatch_metric_alarm.this["ALARM-Critical-Connect-AbbVie_Views-ContactFlowFatalErrors-v2v"].period == 60
    )
    error_message = "Connect alarms must use the V2V instance and the V2V flow and queue names."
  }
}

run "gateway_alarms_watch_the_v2v_gateway_with_its_published_dimensions" {
  command = plan

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.this["ALARM-High-AgentCoreGW-LatencyP99-v2v"].dimensions == tomap({
        Resource  = "arn:aws:bedrock-agentcore:us-east-1:518902362956:gateway/btsgsd-v2v-us-gateway-quick-start-rjqs1usbt7"
        Operation = "InvokeGateway"
        Protocol  = "MCP"
      }) &&
      aws_cloudwatch_metric_alarm.this["ALARM-High-AgentCoreGW-LatencyP99-v2v"].extended_statistic == "p99" &&
      aws_cloudwatch_metric_alarm.this["ALARM-Critical-AgentCoreGW-SystemErrors-v2v"].threshold == 5 &&
      aws_cloudwatch_metric_alarm.this["ALARM-High-AgentCoreGW-Throttles-v2v"].comparison_operator == "GreaterThanOrEqualToThreshold"
    )
    error_message = "Gateway alarms must watch the V2V gateway ARN from its stack output, with the dimensions the gateway publishes."
  }
}

run "gateway_dimensions_can_match_the_console_alarms_exactly" {
  command = plan

  variables {
    gateway_metric_dimensions = {}
  }

  assert {
    condition     = keys(aws_cloudwatch_metric_alarm.this["ALARM-High-AgentCoreGW-Throttles-v2v"].dimensions) == tolist(["Resource"])
    error_message = "An empty map must leave Resource as the only gateway dimension."
  }
}

run "alarms_are_tagged_with_their_priority" {
  command = plan

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.this["ALARM-Critical-AgentCoreGW-SystemErrors-v2v"].tags["Priority"] == "Critical" &&
      aws_cloudwatch_metric_alarm.this["ALARM-Medium-Connect-Instance-MissedCalls-v2v"].tags["Priority"] == "Medium" &&
      aws_cloudwatch_metric_alarm.this["ALARM-Medium-Connect-Instance-MissedCalls-v2v"].tags["Environment"] == "v2v"
    )
    error_message = "Each alarm carries the shared tags plus its priority."
  }
}

run "reject_invalid_email_address" {
  command = plan

  variables {
    alert_email_addresses = ["not-an-address"]
  }

  expect_failures = [var.alert_email_addresses]
}
