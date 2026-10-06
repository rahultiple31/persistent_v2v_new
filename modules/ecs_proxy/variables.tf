variable "name_prefix" {
  description = "Prefix used for proxy ECS resource names."
  type        = string
}

variable "aws_region" {
  description = "AWS Region supplied to the proxy container."
  type        = string
}

variable "container_image" {
  description = "Container image deployed by the ECS task definition."
  type        = string
}

variable "use_bootstrap_container" {
  description = "Whether to run the health-only bootstrap command."
  type        = bool
}

variable "container_port" {
  description = "Proxy container port."
  type        = number
}

variable "desired_count" {
  description = "Baseline number of ECS tasks."
  type        = number
}

variable "task_cpu" {
  description = "Fargate task CPU units."
  type        = number
}

variable "task_memory" {
  description = "Fargate task memory in MiB."
  type        = number
}

variable "health_check_path" {
  description = "Container health-check path."
  type        = string
}

variable "cognito_user_pool_id" {
  description = "Actual Cognito user pool ID from the V2V state."
  type        = string
}

variable "cognito_client_id" {
  description = "Actual Cognito app client ID from the V2V state."
  type        = string
}

variable "allowed_origins" {
  type = list(string)
}
variable "allowed_groups" {
  type = list(string)
}
variable "force_backup_parameter" {
  type = string
}

variable "bedrock_model_id" {
  description = "Bedrock model ID used by the proxy."
  type        = string
}

variable "fallback_rate_limit_per_minute" {
  description = "Per-user fallback API request limit per minute."
  type        = number
}

variable "max_connections_per_user" {
  description = "Per-user WebSocket connection limit."
  type        = number
}

variable "task_execution_role_arn" {
  description = "ARN of the ECS task execution role."
  type        = string
}

variable "task_role_arn" {
  description = "ARN of the proxy application task role."
  type        = string
}

variable "proxy_log_group_name" {
  description = "CloudWatch log group used by the proxy container."
  type        = string
}

variable "service_security_group_id" {
  description = "Security group ID attached to proxy tasks."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs used by proxy tasks."
  type        = list(string)
}

variable "target_group_arn" {
  description = "ALB target group ARN."
  type        = string
}
