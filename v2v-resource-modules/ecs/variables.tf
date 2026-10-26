################################################################################
# ECS Module — Input Variables
################################################################################

variable "stack_name" {
  description = "Stack name prefix applied to every resource name."
  type        = string
}

variable "aws_region" {
  description = "AWS region where the ECS cluster is deployed."
  type        = string
}

variable "subnet_ids" {
  description = "Two private subnet IDs where the Fargate tasks run."
  type        = list(string)
}

variable "service_security_group_id" {
  description = "Security group ID attached to the Fargate proxy tasks."
  type        = string
}

variable "target_group_arn" {
  description = "ARN of the ALB target group to register tasks in."
  type        = string
}

variable "task_role_arn" {
  description = "ARN of the ECS task IAM role (runtime AWS API calls)."
  type        = string
}

variable "execution_role_arn" {
  description = "ARN of the ECS task execution role (ECR pull + CloudWatch Logs)."
  type        = string
}

variable "log_group_name" {
  description = "CloudWatch log group name for container stdout/stderr."
  type        = string
}

variable "container_image_uri" {
  description = "Full container image URI including tag (e.g. 123456789012.dkr.ecr.us-east-1.amazonaws.com/v2v-proxy:latest)."
  type        = string
}

variable "container_environment" {
  description = "List of {name, value} environment variable maps injected into the proxy container."
  type = list(object({
    name  = string
    value = string
  }))
}
