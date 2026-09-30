variable "name_prefix" {
  description = "Prefix used for proxy alarm names."
  type        = string
}

variable "desired_count" {
  description = "Expected healthy target count."
  type        = number
}

variable "target_group_arn_suffix" {
  description = "ALB target group ARN suffix."
  type        = string
}

variable "load_balancer_arn_suffix" {
  description = "ALB ARN suffix."
  type        = string
}

variable "ecs_cluster_name" {
  description = "ECS cluster name."
  type        = string
}

variable "ecs_service_name" {
  description = "ECS service name."
  type        = string
}

variable "nat_gateway_id" {
  description = "NAT gateway ID."
  type        = string
}
