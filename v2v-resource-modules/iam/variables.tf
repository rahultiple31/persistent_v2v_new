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

variable "test_sign_in" {
  description = "true: add IAM permissions for the testSignIn SecureString parameter."
  type        = bool
}

variable "test_sign_in_parameter_arn" {
  description = "ARN of the testSignIn SSM SecureString parameter (created by hand)."
  type        = string
}

variable "log_group_arn" {
  description = "ARN of the CloudWatch log group (grants execution role write access)."
  type        = string
}
