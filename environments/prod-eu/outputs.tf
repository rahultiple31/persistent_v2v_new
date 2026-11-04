output "regional_connect_instances" {
  description = "Amazon Connect deployment outputs for Europe."

  value = {
    "eu-central-1" = {
      region             = "eu-central-1"
      instance_id        = module.connect_eu_central_1[0].instance_id
      instance_arn       = module.connect_eu_central_1[0].instance_arn
      queue_id           = module.connect_eu_central_1[0].queue_id
      routing_profile_id = module.connect_eu_central_1[0].routing_profile_id
      admin_user_id      = module.connect_eu_central_1[0].admin_user_id
    }
  }
}
