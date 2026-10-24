variable "table_name" {
  description = "DynamoDB table name."
  type        = string
  default     = "BTSGSD-V2V-US-queueInfo"
}

variable "kms_key_arn" {
  description = "ARN of an existing customer managed KMS key for table encryption. Null uses an AWS-owned key."
  type        = string
  default     = null
}
