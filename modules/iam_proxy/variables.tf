variable "name_prefix" {
  description = "Prefix used for proxy IAM resource names."
  type        = string
}

variable "aws_region" {
  description = "AWS Region allowed by the proxy task policy."
  type        = string
}

variable "bedrock_model_id" {
  description = "Bedrock model ID the proxy task may invoke."
  type        = string
}

variable "force_backup_parameter" {
  description = "Full SSM parameter name used for the runtime backup translation switch."
  type        = string
}
