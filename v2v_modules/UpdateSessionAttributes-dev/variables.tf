variable "function_name" {
  description = "Lambda function name."
  type        = string
  default     = "BTSGSD-V2V-US-UpdateSessionAttributes"
}

variable "zip_path" {
  description = "Deployment ZIP path. Generated from source_file when set; otherwise an existing ZIP containing lambda_function.py and warmup_wrapper.py at its root."
  type        = string
}

variable "source_file" {
  description = "Optional Python source to package at the root of zip_path."
  type        = string
  default     = null
}

variable "connect_instance_arn" {
  type = string
}

variable "assistant_id" {
  description = "Amazon Q in Connect assistant UUID."
  type        = string
}

variable "common_tags" {
  type    = map(string)
  default = {}
}
