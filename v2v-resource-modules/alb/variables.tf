################################################################################
# ALB Module — Input Variables
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
  description = "Two private subnet IDs where the ALB is placed."
  type        = list(string)
}

variable "alb_security_group_id" {
  description = "Security group ID to attach to the ALB."
  type        = string
}

variable "https" {
  description = "true = HTTPS listener on 443; false = HTTP listener on 80."
  type        = bool
}

variable "listener_port" {
  description = "Listener port (80 or 443)."
  type        = number
}

variable "certificate_arn" {
  description = "ACM certificate ARN. Required when https = true."
  type        = string
  default     = ""
}

variable "account_id" {
  description = "AWS account ID — used to build the ALB log bucket policy resource path."
  type        = string
}
