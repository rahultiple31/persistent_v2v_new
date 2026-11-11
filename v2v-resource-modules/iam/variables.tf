################################################################################
# IAM Module — Input Variables
################################################################################

variable "stack_name" {
  description = "Stack name prefix applied to every resource name."
  type        = string
}

variable "aws_region" {
  description = "AWS region where the stack is deployed."
  type        = string
}

variable "ai_region" {
  description = "Region for Nova Sonic, Transcribe, Translate and Polly calls."
  type        = string
}

variable "partition" {
  description = "AWS partition (aws, aws-cn, aws-us-gov)."
  type        = string
}

variable "account_id" {
  description = "AWS account ID."
  type        = string
}

variable "nova_sonic_model_id" {
  description = "Bedrock foundation model ID the task role is allowed to invoke."
  type        = string
}

variable "force_backup_parameter_arn" {
  description = "ARN of the forceBackupTranslation SSM parameter (read-only access)."
  type        = string
}

variable "log_group_arn" {
  description = "ARN of the CloudWatch log group (grants execution role write access)."
  type        = string
}

variable "secret_names" {
  description = "Names of the Secrets Manager secrets the task may read (server-side sign-in, test sign-in password). Empty: no Secrets Manager access."
  type        = list(string)
  default     = []
}

variable "voicemail_recordings_bucket" {
  description = "VMX3 recordings bucket the task may read voicemail recordings (.wav) from. Empty: no S3 access."
  type        = string
  default     = ""
}
