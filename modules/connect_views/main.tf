resource "awscc_connect_view" "customer_details" {
  name         = var.view_name
  instance_arn = var.connect_instance_arn
  description  = "Customer Details View"
  actions      = ["Close"]
  template     = var.view_template

  tags = [for key, value in var.common_tags : {
    key   = key
    value = value
  }]
}
