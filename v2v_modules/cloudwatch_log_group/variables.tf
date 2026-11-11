variable "log_group_name" {
  description = "CloudWatch log group name."
  type        = string
}

variable "retention_in_days" {
  description = "Days to keep log events. Null keeps them indefinitely."
  type        = number
  default     = null
}

variable "kms_key_id" {
  description = "ARN of the KMS key that encrypts the log group. Null uses the default CloudWatch Logs encryption."
  type        = string
  default     = null
}

variable "log_group_class" {
  description = "STANDARD, INFREQUENT_ACCESS or DELIVERY. Null keeps the provider default (STANDARD)."
  type        = string
  default     = null

  validation {
    condition     = var.log_group_class == null || contains(["STANDARD", "INFREQUENT_ACCESS", "DELIVERY"], coalesce(var.log_group_class, "STANDARD"))
    error_message = "log_group_class must be STANDARD, INFREQUENT_ACCESS or DELIVERY."
  }
}

variable "tags" {
  description = "Tags for the log group. Null sets none."
  type        = map(string)
  default     = null
}
