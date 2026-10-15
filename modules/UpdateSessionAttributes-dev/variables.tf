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
