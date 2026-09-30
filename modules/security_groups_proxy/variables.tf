variable "name_prefix" {
  description = "Prefix used for proxy security-group names."
  type        = string
}

variable "vpc_id" {
  description = "Proxy VPC ID."
  type        = string
}

variable "container_port" {
  description = "Proxy container port."
  type        = number
}
