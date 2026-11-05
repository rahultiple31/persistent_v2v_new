variable "bucket_name" {
  description = "S3 bucket whose default encryption is managed by this module."
  type        = string
}

variable "tags" {
  description = "Tags applied to the bucket's KMS key."
  type        = map(string)
  default     = {}
}
