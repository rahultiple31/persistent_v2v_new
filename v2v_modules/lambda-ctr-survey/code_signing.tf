variable "code_signing_config_arn" {
  description = "Lambda code-signing configuration ARN supplied by the environment."
  type        = string
  default     = "arn:aws:lambda:us-east-1:518902362956:code-signing-config:csc-07e3c2263fd84c053"
}
