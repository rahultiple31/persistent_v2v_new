output "regional_connect_instances" {
  description = "Amazon Connect deployment outputs for APAC."

  value = {
    "ap-southeast-1" = {
      region             = "ap-southeast-1"
      instance_id        = module.connect_ap_southeast_1[0].instance_id
      instance_arn       = module.connect_ap_southeast_1[0].instance_arn
      queue_id           = module.connect_ap_southeast_1[0].queue_id
      routing_profile_id = module.connect_ap_southeast_1[0].routing_profile_id
      admin_user_id      = module.connect_ap_southeast_1[0].admin_user_id
    }
  }
}
