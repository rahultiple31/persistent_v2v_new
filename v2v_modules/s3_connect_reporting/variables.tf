variable "bucket_name" {
  description = "S3 bucket name for Connect reporting."
  type        = string
}

variable "common_tags" {
  description = "Common resource tags."
  type        = map(string)
  default     = {}
}
