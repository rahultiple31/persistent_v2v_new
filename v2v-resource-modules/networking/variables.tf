################################################################################
# Networking Module — Input Variables
################################################################################

variable "stack_name" {
  description = "Stack name prefix applied to every resource name."
  type        = string
}

variable "vpc_id" {
  description = "ID of the existing VPC."
  type        = string
}

variable "subnet_ids" {
  description = "Two private subnet IDs for VPC endpoint placement."
  type        = list(string)
}

variable "aws_region" {
  description = "AWS region — used to build VPC endpoint service names."
  type        = string
}

variable "allowed_cidrs" {
  description = "CIDRs allowed to reach the load balancer listener."
  type        = list(string)
}

variable "endpoint_extra_cidrs" {
  description = "Additional VPC CIDRs that call the AWS AI services and must reach the interface endpoints."
  type        = list(string)
  default     = []
}

variable "listener_port" {
  description = "ALB listener port (80 for HTTP, 443 for HTTPS)."
  type        = number
}
