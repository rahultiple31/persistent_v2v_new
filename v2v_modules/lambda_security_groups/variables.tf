variable "vpc_id" {
  description = "VPC containing the Lambda functions and interface endpoints."
  type        = string
  default     = "vpc-0f2abb3d6596a0487"
}

variable "common_tags" {
  type    = map(string)
  default = {}
}
