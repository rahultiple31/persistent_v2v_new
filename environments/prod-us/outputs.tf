output "regional_connect_instances" {
  description = "Amazon Connect deployment outputs by region."

  value = {
    "us-east-1" = {
      region             = "us-east-1"
      instance_id        = module.connect_us_east_1[0].instance_id
      instance_arn       = module.connect_us_east_1[0].instance_arn
      queue_id           = module.connect_us_east_1[0].queue_id
      routing_profile_id = module.connect_us_east_1[0].routing_profile_id
      admin_user_id      = module.connect_us_east_1[0].admin_user_id
    }
  }
}
