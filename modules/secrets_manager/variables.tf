variable "secrets" {
  description = "Secret names and their key/value payloads."
  type        = map(map(string))
  sensitive   = true
}

variable "common_tags" {
  type    = map(string)
  default = {}
}
