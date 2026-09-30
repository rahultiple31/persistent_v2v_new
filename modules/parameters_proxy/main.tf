resource "aws_ssm_parameter" "proxy_enabled" {
  name        = "${var.ssm_parameter_prefix}/proxyEnabled"
  description = "Feature switch for the translation proxy."
  type        = "String"
  value       = tostring(var.proxy_enabled)
  overwrite   = true
}

resource "aws_ssm_parameter" "proxy_availability_zones" {
  name        = "${var.ssm_parameter_prefix}/proxyAvailabilityZones"
  description = "Comma-separated AZ names used by the translation proxy."
  type        = "String"
  value       = join(",", var.selected_availability_zones)
  overwrite   = true
}
