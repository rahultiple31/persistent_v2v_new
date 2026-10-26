################################################################################
# ECR Module — Input Variables
################################################################################

variable "repository_name" {
  description = "Name of the ECR repository that holds the proxy container image."
  type        = string
}
