variable "connect_instance_arn" {
  description = "Amazon Connect instance allowed to invoke the Lambda."
  type        = string
}

variable "common_tags" {
  type    = map(string)
  default = {}
}
