variable "assistant_id" {
  description = "Existing assistant UUID used by the survey AI agent."
  type        = string
}

variable "prompt_yaml_file" {
  description = "Path to the YAML containing the complete survey prompt."
  type        = string
}
