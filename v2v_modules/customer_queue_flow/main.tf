module "flow" {
  source = "../connect_flow_resource"

  flow = merge(var.settings, {
    name        = "BTSGSD-V2V-US-CustomerQueueFlow"
    type        = "CUSTOMER_QUEUE"
    description = "Imported flow: BTSGSD-V2V-US-CustomerQueueFlow"
    content = replace(
      replace(
        file("${path.module}/assets/BTSGSD_Abbvie_CustomerQueueFlow.json"),
        "arn:aws:lambda:us-east-1:518902362956:function:conversionOfQueueMetrics-dev",
        var.settings.queue_metrics_lambda_arn
      ),
      "0c2359aa-9062-43ec-9d0d-abc5861c2197",
      var.settings.survey_data_table_id
    )
    resolve_dependencies = true
  })
}
