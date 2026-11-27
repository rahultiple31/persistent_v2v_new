variable "function_arn" {
  type = string
}

variable "subnet_ids" {
  type = set(string)
}

variable "security_group_ids" {
  type = set(string)
}

variable "ipv6_allowed_for_dual_stack" {
  type = bool
}
