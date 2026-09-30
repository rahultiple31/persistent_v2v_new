variable "name_prefix" {
  description = "Prefix used for proxy log resource names."
  type        = string
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention in days."
  type        = number
}

variable "vpc_id" {
  description = "Proxy VPC ID."
  type        = string
}
