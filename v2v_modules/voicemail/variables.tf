variable "name_prefix" {
  description = "Prefix applied to every voicemail resource name."
  type        = string
  default     = "BTSGSD-V2V-US"
  nullable    = false
}

variable "instance_arn" {
  description = "Target (V2V) Amazon Connect instance ARN."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^arn:aws:connect:[a-z0-9-]+:[0-9]{12}:instance/[0-9a-f-]+$", var.instance_arn))
    error_message = "Provide a valid Amazon Connect instance ARN."
  }
}

variable "voicemail_queue_arn" {
  description = "Voicemail queue ARN in the target instance (VMX3 tasks are routed here)."
  type        = string
  nullable    = false
}

variable "voicemail_queue_name" {
  description = "Display name of the voicemail queue, used only in the flow module metadata."
  type        = string
  default     = "BTSGSD-V2V-US-VM-QUEUE"
}

variable "beep_prompt_arn" {
  description = "Beep.wav prompt ARN in the target instance."
  type        = string
  nullable    = false
}

variable "prompt_data_table_id" {
  description = "Data table ID holding voiceMailSaved and voiceMailModuleError messages by Language."
  type        = string
  nullable    = false
}

variable "prompt_data_table_name" {
  description = "Display name of the prompt data table, used only in the flow module metadata."
  type        = string
  default     = "BTSGSD-V2V-US-PROMPT-DATATABLE"
}

variable "customer_queue_flow_name" {
  description = "Customer queue flow set as the CustomerQueue event hook in the task flow."
  type        = string
  default     = "Default customer queue"
}

variable "presigner_user_name" {
  description = "Existing IAM user whose access key signs the recording URLs. The user itself is not modified."
  type        = string
  default     = "VMX3_Presigner_User_btsgsd-dev-us-east-1"
}

variable "create_presigner_access_key" {
  description = "Create a new access key for the existing presigner user and store it in the secret. Set false to supply presigner_credentials instead."
  type        = bool
  default     = true
}

variable "presigner_credentials" {
  description = "Existing presigner access key, used only when create_presigner_access_key is false."
  type = object({
    access_key_id     = string
    secret_access_key = string
  })
  default   = null
  sensitive = true
}

variable "connect_recordings_bucket_name" {
  description = "Bucket where the instance stores call recordings (read by RecordingProcessor)."
  type        = string
  nullable    = false
}

variable "associate_ctr_stream" {
  description = "Stream the instance's contact trace records to the new Kinesis stream. Connect allows one CTR stream; remove the existing association first."
  type        = bool
  default     = false
}

variable "code_signing_config_arn" {
  description = "Lambda code signing configuration ARN."
  type        = string
  default     = null
}

variable "otel_layer_arn" {
  description = "AWS Distro for OpenTelemetry Python layer used by the existing functions."
  type        = string
  default     = "arn:aws:lambda:us-east-1:615299751070:layer:AWSOpenTelemetryDistroPython:32"
}

variable "log_retention_days" {
  description = "CloudWatch log retention for the voicemail functions."
  type        = number
  default     = 90
}

variable "recording_expiration_days" {
  description = "V2VDeletePolicy lifecycle expiration (days), copied from the existing buckets."
  type        = number
  default     = 7
}

variable "url_expiration_days" {
  description = "Presigned URL validity (days) for task and email delivery."
  type        = number
  default     = 7
}

variable "packager_settings" {
  description = "Packager environment values copied from voicemail-v2v-Packager."
  type = object({
    timezone             = optional(string, "America/New_York")
    do_genai_summary     = optional(string, "false")
    inference_model      = optional(string, "us.amazon.nova-lite-v1:0")
    inference_region     = optional(string, "us-east-1")
    agent_email_key      = optional(string, "Email")
    default_vmx_mode     = optional(string, "task")
    default_email_target = optional(string, "AWS::NoValue")
    default_email_from   = optional(string, "AWS::NoValue")
    agent_email_template = optional(string, "AWS::NoValue")
    queue_email_template = optional(string, "AWS::NoValue")
    guided_task_flow     = optional(string, "AWS::NoValue")
  })
  default = {}
}

variable "package_version" {
  description = "VMX3 package version reported by the functions."
  type        = string
  default     = "2025.09.13"
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}
