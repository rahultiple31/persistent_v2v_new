variable "name_prefix" {
  description = "Prefix used for proxy autoscaling resource names."
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

variable "min_capacity" {
  description = "Minimum ECS service task count."
  type        = number
}

variable "max_capacity" {
  description = "Maximum ECS service task count."
  type        = number
}
