################################################################################
# SSM Module — Input Variables
################################################################################

variable "stack_name" {
  description = "Stack name prefix applied to every resource name."
  type        = string
}

variable "ssm_hierarchy" {
  description = "Parameter Store key prefix (must end with /). Example: /V2V/POC/"
  type        = string
}

variable "ai_region" {
  description = "Region the proxy uses for Nova Sonic, Transcribe, Translate and Polly."
  type        = string
}
