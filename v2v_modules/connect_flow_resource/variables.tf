variable "flow" {
  description = "Rendered contact flow and its target-instance dependencies."
  type = object({
    name                  = string
    type                  = string
    description           = string
    content               = string
    instance_arn          = string
    expected_instance_arn = optional(string)
    tags                  = optional(map(string), {})
    resolve_dependencies  = optional(bool, false)
    dependency_names      = optional(map(string), {})
    python_executable     = optional(string, "python3")
  })
}
