variable "name_prefix" {
  description = "Default ECR repository name."
  type        = string
}

variable "ecr_repository_name" {
  description = "Optional ECR repository name override."
  type        = string
  default     = null
}
