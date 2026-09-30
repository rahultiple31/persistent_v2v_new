variable "aws_region" {
  description = "AWS Region for the proxy network."
  type        = string
}

variable "name_prefix" {
  description = "Prefix used for proxy network resource names."
  type        = string
}

variable "availability_zones" {
  description = "Optional pair of Availability Zone names."
  type        = list(string)
  default     = null
}

variable "vpc_cidr" {
  description = "CIDR block for the proxy VPC."
  type        = string
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for the two public subnets."
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for the two private subnets."
  type        = list(string)
}
