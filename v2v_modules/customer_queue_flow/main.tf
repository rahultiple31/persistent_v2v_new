locals {
  export = file("${path.module}/assets/BTSGSD_Abbvie_CustomerQueueFlow.json")
  # Connect instances and Lex bots of the source export; none may remain once
  # the dependencies are resolved for the target instance.
  source_references = distinct(concat(
    [for match in regexall("instance/([0-9a-f-]{36})", local.export) : match[0]],
    [for match in regexall("bot-alias/([0-9A-Z]{10})/", local.export) : match[0]],
  ))
}

module "flow" {
  source = "../connect_flow_resource"
  flow = merge(var.settings, {
    name        = "BTSGSD-V2V-US-CustomerQueueFlow"
    type        = "CUSTOMER_QUEUE"
    description = "Imported flow: BTSGSD-V2V-US-CustomerQueueFlow"
    content = replace(
      replace(
        local.export,
        "arn:aws:lambda:us-east-1:518902362956:function:conversionOfQueueMetrics-dev",
        var.settings.queue_metrics_lambda_arn
      ),
      "0c2359aa-9062-43ec-9d0d-abc5861c2197",
      var.settings.survey_data_table_id
    )
    resolve_dependencies = true
    forbidden_references = local.source_references
  })
}
