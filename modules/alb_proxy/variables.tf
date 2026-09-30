variable "name_prefix" {
  description = "Prefix used for proxy ALB resource names."
  type        = string
}

variable "alb_security_group_id" {
  description = "Security group ID attached to the internal ALB."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs used by the internal ALB."
  type        = list(string)
}

variable "vpc_id" {
  description = "Proxy VPC ID."
  type        = string
}

variable "container_port" {
  description = "Proxy target port."
  type        = number
}

variable "health_check_path" {
  description = "Proxy health-check path."
  type        = string
}
