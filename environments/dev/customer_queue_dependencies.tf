resource "aws_lambda_permission" "queue_metrics_connect" {
  count    = local.deploy_connect ? 1 : 0
  provider = aws.us_east_1

  statement_id  = "AllowConnectCustomerQueueMetrics"
  action        = "lambda:InvokeFunction"
  function_name = module.conversion_of_queue_metrics[0].lambda_name
  principal     = "connect.amazonaws.com"

  source_arn     = module.connect_us_east_1[0].instance_arn
  source_account = split(":", module.connect_us_east_1[0].instance_arn)[4]
}

resource "aws_connect_lambda_function_association" "queue_metrics" {
  count    = local.deploy_connect ? 1 : 0
  provider = aws.us_east_1

  instance_id  = module.connect_us_east_1[0].instance_id
  function_arn = module.conversion_of_queue_metrics[0].lambda_arn

  depends_on = [aws_lambda_permission.queue_metrics_connect]
}
