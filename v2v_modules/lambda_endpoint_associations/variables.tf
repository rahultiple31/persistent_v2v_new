variable "vpc_id" {
  type    = string
  default = "vpc-0f2abb3d6596a0487"
}

variable "endpoint_security_group_name" {
  description = "Existing security group to add to the five interface endpoints."
  type        = string
  default     = "BTSGSD-V2V-US-LAMBDA-endpoint-sg"
}
