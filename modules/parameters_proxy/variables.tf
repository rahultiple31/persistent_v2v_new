variable "ssm_parameter_prefix" {
  description = "SSM path prefix for proxy settings."
  type        = string
}

variable "proxy_enabled" {
  description = "Proxy feature-switch value."
  type        = bool
}

variable "selected_availability_zones" {
  description = "Availability Zones selected for the proxy deployment."
  type        = list(string)
}
