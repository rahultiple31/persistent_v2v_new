variable "function_name" {
  description = "Lambda function name."
  type        = string
  default     = "BTSGSD-V2V-US-UpdateSessionAttributes"
}

variable "zip_path" {
  description = "Existing ZIP containing lambda_function.py at its root."
  type        = string
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
