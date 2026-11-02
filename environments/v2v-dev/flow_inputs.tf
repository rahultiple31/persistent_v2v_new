locals {
  connect_flow_settings = local.deploy_connect ? {
    instance_arn          = module.connect_us_east_1[0].instance_arn
    expected_instance_arn = local.connect_target_instance_arn
    dependency_names      = var.connect_customer_queue_dependency_names
    python_executable     = var.connect_flow_python_executable
    tags                  = local.common_tags
  } : null

  # Preserve the tags previously applied by the Connect imported-flow resource.
  imported_flow_settings = local.deploy_connect ? merge(local.connect_flow_settings, {
    tags = merge(local.common_tags, {
      RegionCode = "us-east-1"
      AWSRegion  = "us-east-1"
      Service    = var.connect_name_suffix
    })
  }) : null
}
