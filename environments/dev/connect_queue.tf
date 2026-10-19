module "connect_queue" {
  count  = local.deploy_connect ? 1 : 0
  source = "../../modules/connect-queue"

  providers = {
    aws = aws.us_east_1
  }

  instance_alias           = var.connect_instance_alias
  queue_name               = var.queue_name
  outbound_phone_number_id = var.outbound_phone_number_id
  outbound_flow_name       = "Default outbound"

  tags = merge(local.common_tags, {
    Env = "Dev"
    Org = "btsgsd"
  })
}

output "connect_queue" {
  value = try({
    queue_id              = module.connect_queue[0].queue_id
    queue_arn             = module.connect_queue[0].queue_arn
    hours_of_operation_id = module.connect_queue[0].hours_of_operation_id
    quick_connect_ids     = module.connect_queue[0].quick_connect_ids
  }, null)
}
